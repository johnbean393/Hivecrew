/**
 * Hivecrew Web UI - Alpine.js Application
 */

console.log('[Hivecrew] app.js loaded');

// Register the main Alpine.js component
document.addEventListener('alpine:init', () => {
    console.log('[Hivecrew] Alpine initializing...');
    Alpine.data('hivecrew', () => ({

        // -------------------------------------------------------------------
        // --- Data Properties ------------------------------------------------
        // -------------------------------------------------------------------

        // Authentication
        authenticated: false,
        authMode: 'pairing', // 'pairing' or 'apikey'
        apiKey: localStorage.getItem('hivecrew_api_key') || '',
        apiKeyInput: '',
        authError: '',
        authMethod: null, // 'cookie', 'bearer', or null
        
        // Device Pairing
        pairingId: null,
        pairingCode: null,
        pairingStatus: null, // 'pending', 'approved', 'rejected', 'expired'
        pairingLoading: false,
        pairingPollTimer: null,
        
        // Navigation
        view: 'tasks',
        
        // Tasks
        tasks: [],
        scheduledTasks: [],
        selectedTask: null,
        loading: false,
        statusFilter: '',
        searchQuery: '',
        
        // Quick Create
        quickTaskDescription: '',
        quickCreating: false,
        quickPlanFirst: localStorage.getItem('hivecrew_plan_first') === 'true',
        quickFiles: [],
        quickModelId: localStorage.getItem('hivecrew_model_id') || '',
        isDraggingFiles: false,
        
        // Create Task
        showCreateModal: false,
        isScheduling: false,
        creating: false,
        createError: '',
        newTask: {
            title: '',
            description: '',
            providerId: '',
            modelId: '',
            planFirst: false,
            isRecurring: false,
            scheduleDate: '',
            scheduleTime: '09:00',
            recurrenceType: 'weekly',
            daysOfWeek: [2], // 1=Sunday, 2=Monday, etc.
            dayOfMonth: 1,
            files: [] // Supports both immediate and scheduled tasks
        },
        
        // Plan review
        editedPlanMarkdown: '',
        planEditing: false,
        
        // Selected schedule (for detail view)
        selectedSchedule: null,
        
        // Providers & Models
        providers: [],
        availableModels: [],
        modelDropdownOpen: false,
        modelSearchQuery: '',
        
        // System Status
        systemStatus: null,
        
        // Screenshot
        screenshotUrl: '',
        screenshotTimer: null,
        
        // Event Stream (polling)
        taskEvents: [],
        eventSince: 0,
        eventTimer: null,
        
        // Task Actions
        actionLoading: false,
        instructionsText: '',
        answerText: '',
        
        // Pending Alerts (questions/permissions from running tasks, shown as popups)
        pendingAlerts: [],
        pendingAlertAnswer: '',
        pendingAlertDismissed: new Set(),
        
        // Toasts
        toasts: [],
        toastId: 0,
        
        // Auto-refresh & elapsed time
        refreshTimer: null,
        tickInterval: null,
        now: Date.now(),

        // -------------------------------------------------------------------
        // --- Initialization & Persistence ----------------------------------
        // -------------------------------------------------------------------

        async init() {
            console.log('[Hivecrew] Component init() called');
            this.creating = false;
            
            // Initialize Mermaid for diagram rendering
            if (typeof mermaid !== 'undefined') {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
                    securityLevel: 'loose'
                });
            }
            
            // Configure marked to preserve mermaid code blocks with a recognizable class
            if (typeof marked !== 'undefined') {
                const renderer = new marked.Renderer();
                const originalCode = renderer.code?.bind(renderer);
                renderer.code = function({ text, lang }) {
                    if (lang === 'mermaid') {
                        return '<pre><code class="language-mermaid">' + text + '</code></pre>';
                    }
                    const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                    return '<pre><code' + (lang ? ' class="language-' + lang + '"' : '') + '>' + escaped + '</code></pre>';
                };
                marked.setOptions({ renderer, breaks: false, gfm: true });
            }
            
            // Check if already authenticated (via cookie or stored API key)
            await this.checkAuth();
            
            if (this.authenticated) {
                await this.loadInitialData();
                this.startAutoRefresh();
                this.restoreSelections();
            } else {
                // Auto-request pairing code on load
                this.requestPairingCode();
            }
            
            // Set default schedule date to tomorrow
            const tomorrow = new Date();
            tomorrow.setDate(tomorrow.getDate() + 1);
            this.newTask.scheduleDate = tomorrow.toISOString().split('T')[0];
            console.log('[Hivecrew] Component init() complete');
        },
        
        saveModelSelection() {
            if (this.newTask.modelId) {
                localStorage.setItem('hivecrew_model_id', this.newTask.modelId);
                this.quickModelId = this.newTask.modelId;
            }
        },
        
        saveProviderSelection() {
            if (this.newTask.providerId) {
                localStorage.setItem('hivecrew_provider_id', this.newTask.providerId);
            }
        },
        
        restoreSelections() {
            const savedProviderId = localStorage.getItem('hivecrew_provider_id');
            const savedModelId = localStorage.getItem('hivecrew_model_id');
            
            if (savedProviderId && this.providers.some(p => p.id === savedProviderId)) {
                this.newTask.providerId = savedProviderId;
            }
            
            if (savedModelId) {
                this.newTask.modelId = savedModelId;
                this.quickModelId = savedModelId;
            }
        },

        // -------------------------------------------------------------------
        // --- Authentication ------------------------------------------------
        // -------------------------------------------------------------------

        /// Check if the current session is authenticated (cookie or Bearer)
        async checkAuth() {
            try {
                const headers = {};
                if (this.apiKey) {
                    headers['Authorization'] = `Bearer ${this.apiKey}`;
                }
                const response = await fetch('/api/v1/auth/check', {
                    credentials: 'include',
                    headers
                });
                if (response.ok) {
                    const data = await response.json();
                    if (data.authenticated) {
                        this.authenticated = true;
                        this.authMethod = data.method;
                        console.log('[Hivecrew] Authenticated via', data.method);
                        return;
                    }
                }
            } catch (error) {
                console.error('[Hivecrew] Auth check failed:', error);
            }
            this.authenticated = false;
            this.authMethod = null;
        },
        
        /// Request a new pairing code from the server
        async requestPairingCode() {
            this.authError = '';
            this.pairingLoading = true;
            this.pairingCode = null;
            this.pairingStatus = null;
            this.stopPairingPoll();
            
            try {
                const response = await fetch('/api/v1/auth/pair/request', {
                    method: 'POST',
                    credentials: 'include',
                    headers: { 'Content-Type': 'application/json' }
                });
                
                if (!response.ok) {
                    const errorData = await response.json().catch(() => ({}));
                    this.authError = errorData.error?.message || 'Failed to request pairing code.';
                    this.pairingLoading = false;
                    return;
                }
                
                const data = await response.json();
                this.pairingId = data.pairingId;
                this.pairingCode = data.code;
                this.pairingStatus = 'pending';
                this.pairingLoading = false;
                
                // Start polling for approval
                this.startPairingPoll();
                
            } catch (error) {
                this.authError = 'Connection failed. Is the server running?';
                this.pairingLoading = false;
            }
        },
        
        /// Poll for pairing status
        startPairingPoll() {
            this.stopPairingPoll();
            this.pairingPollTimer = setInterval(() => this.pollPairingStatus(), 2000);
        },
        
        stopPairingPoll() {
            if (this.pairingPollTimer) {
                clearInterval(this.pairingPollTimer);
                this.pairingPollTimer = null;
            }
        },
        
        async pollPairingStatus() {
            if (!this.pairingId) return;
            
            try {
                const response = await fetch(`/api/v1/auth/pair/status?id=${encodeURIComponent(this.pairingId)}`, {
                    credentials: 'include'
                });
                
                if (!response.ok) {
                    // Pairing may have expired
                    this.pairingStatus = 'expired';
                    this.stopPairingPoll();
                    return;
                }
                
                const data = await response.json();
                this.pairingStatus = data.status;
                
                if (data.status === 'approved') {
                    // Server set the cookie via Set-Cookie header
                    this.stopPairingPoll();
                    this.authenticated = true;
                    this.authMethod = 'cookie';
                    this.pairingCode = null;
                    this.pairingId = null;
                    
                    // Load initial data
                    await this.loadInitialData();
                    this.startAutoRefresh();
                    this.restoreSelections();
                    
                } else if (data.status === 'rejected' || data.status === 'expired') {
                    this.stopPairingPoll();
                }
                
            } catch (error) {
                console.error('[Hivecrew] Pairing poll error:', error);
            }
        },

        /// API key login (fallback mode)
        async saveApiKey() {
            if (!this.apiKeyInput) return;
            
            this.authError = '';
            
            try {
                const response = await fetch('/api/v1/system/status', {
                    headers: {
                        'Authorization': `Bearer ${this.apiKeyInput}`
                    }
                });
                
                if (response.status === 401) {
                    this.authError = 'Invalid API key. Please check and try again.';
                    return;
                }
                
                if (!response.ok) {
                    this.authError = 'Failed to connect. Is the API server running?';
                    return;
                }
                
                // Save the key
                this.apiKey = this.apiKeyInput;
                localStorage.setItem('hivecrew_api_key', this.apiKey);
                this.apiKeyInput = '';
                this.authenticated = true;
                this.authMethod = 'bearer';
                
                // Load initial data
                await this.loadInitialData();
                this.startAutoRefresh();
                
            } catch (error) {
                this.authError = 'Connection failed. Please check the server is running.';
            }
        },
        
        async logout() {
            // Clear session cookie via server
            try {
                await fetch('/api/v1/auth/logout', {
                    method: 'POST',
                    credentials: 'include',
                    headers: this.apiKey ? { 'Authorization': `Bearer ${this.apiKey}` } : {}
                });
            } catch (error) {
                // Ignore errors during logout
            }
            
            this.authenticated = false;
            this.authMethod = null;
            this.apiKey = '';
            localStorage.removeItem('hivecrew_api_key');
            this.stopAutoRefresh();
            this.stopPairingPoll();
            this.tasks = [];
            this.scheduledTasks = [];
            this.providers = [];
            this.pairingCode = null;
            this.pairingId = null;
            this.pairingStatus = null;
            
            // Request a new pairing code for the login screen
            this.requestPairingCode();
        },

        // -------------------------------------------------------------------
        // --- API Helpers ---------------------------------------------------
        // -------------------------------------------------------------------

        /**
         * Authenticated fetch wrapper.
         *
         * Adds the Authorization header to every request and sets
         * Content-Type to application/json unless the caller supplies
         * a FormData body (in which case the browser sets the correct
         * multipart Content-Type automatically).
         */
        async apiFetch(endpoint, options = {}) {
            console.log('[Hivecrew] apiFetch:', options.method || 'GET', endpoint);
            
            const headers = {
                ...options.headers
            };
            
            // Add Bearer token if using API key auth
            if (this.apiKey) {
                headers['Authorization'] = `Bearer ${this.apiKey}`;
            }
            
            // Only set Content-Type for non-FormData bodies
            const isFormData = typeof FormData !== 'undefined' && options.body instanceof FormData;
            if (!isFormData && !headers['Content-Type']) {
                headers['Content-Type'] = 'application/json';
            }
            
            const response = await fetch(endpoint, {
                ...options,
                headers,
                credentials: 'include'
            });
            
            console.log('[Hivecrew] apiFetch response:', response.status, endpoint);
            
            if (response.status === 401) {
                // Session may have expired — show login
                this.authenticated = false;
                this.authMethod = null;
                throw new Error('Unauthorized');
            }
            
            return response;
        },

        // -------------------------------------------------------------------
        // --- Data Loading --------------------------------------------------
        // -------------------------------------------------------------------

        async loadInitialData() {
            await Promise.all([
                this.loadTasks(),
                this.loadProviders(),
                this.loadSystemStatus()
            ]);
        },
        
        async loadTasks() {
            this.loading = true;
            try {
                let url = '/api/v1/tasks?limit=100&sort=createdAt&order=desc';
                if (this.statusFilter) {
                    url += `&status=${this.statusFilter}`;
                }
                
                const response = await this.apiFetch(url);
                if (response.ok) {
                    const data = await response.json();
                    this.tasks = data.tasks || [];
                }
            } catch (error) {
                console.error('Failed to load tasks:', error);
            } finally {
                this.loading = false;
            }
        },
        
        async checkPendingAlerts() {
            const runningTasks = this.tasks.filter(t => 
                ['running', 'queued', 'waiting_for_vm'].includes(t.status)
            );
            
            const alerts = [];
            for (const task of runningTasks) {
                try {
                    const response = await this.apiFetch(`/api/v1/tasks/${task.id}`);
                    if (response.ok) {
                        const fullTask = await response.json();
                        if (fullTask.pendingQuestion && !this.pendingAlertDismissed.has(fullTask.pendingQuestion.id)) {
                            alerts.push({
                                type: 'question',
                                task: fullTask,
                                id: fullTask.pendingQuestion.id
                            });
                        }
                        if (fullTask.pendingPermission && !this.pendingAlertDismissed.has(fullTask.pendingPermission.id)) {
                            alerts.push({
                                type: 'permission',
                                task: fullTask,
                                id: fullTask.pendingPermission.id
                            });
                        }
                    }
                } catch (error) {
                    // Silently ignore errors
                }
            }
            this.pendingAlerts = alerts;
        },
        
        async submitAlertAnswer(alert, answer) {
            const text = (answer || this.pendingAlertAnswer || '').trim();
            if (!text) return;
            
            this.actionLoading = true;
            try {
                const response = await this.apiFetch(
                    `/api/v1/tasks/${alert.task.id}/question/answer`,
                    {
                        method: 'POST',
                        body: JSON.stringify({
                            questionId: alert.task.pendingQuestion.id,
                            answer: text
                        })
                    }
                );
                
                if (!response.ok && response.status !== 204) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to submit answer');
                }
                
                this.pendingAlertAnswer = '';
                this.pendingAlertDismissed.add(alert.id);
                this.pendingAlerts = this.pendingAlerts.filter(a => a.id !== alert.id);
                this.showToast('Answer submitted', 'success');
                await this.loadTasks();
                if (this.selectedTask?.id === alert.task.id) {
                    await this.refreshSelectedTask();
                }
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async respondAlertPermission(alert, approved) {
            this.actionLoading = true;
            try {
                const response = await this.apiFetch(
                    `/api/v1/tasks/${alert.task.id}/permission/respond`,
                    {
                        method: 'POST',
                        body: JSON.stringify({
                            permissionId: alert.task.pendingPermission.id,
                            approved: approved
                        })
                    }
                );
                
                if (!response.ok && response.status !== 204) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to respond to permission');
                }
                
                this.pendingAlertDismissed.add(alert.id);
                this.pendingAlerts = this.pendingAlerts.filter(a => a.id !== alert.id);
                this.showToast(approved ? 'Permission granted' : 'Permission denied', 'success');
                await this.loadTasks();
                if (this.selectedTask?.id === alert.task.id) {
                    await this.refreshSelectedTask();
                }
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        dismissAlert(alert) {
            this.pendingAlertDismissed.add(alert.id);
            this.pendingAlerts = this.pendingAlerts.filter(a => a.id !== alert.id);
        },
        
        get filteredTasks() {
            if (!this.searchQuery.trim()) return this.tasks;
            const q = this.searchQuery.toLowerCase();
            return this.tasks.filter(t =>
                (t.title && t.title.toLowerCase().includes(q)) ||
                (t.modelId && t.modelId.toLowerCase().includes(q))
            );
        },
        
        get filteredModels() {
            if (!this.modelSearchQuery.trim()) return this.availableModels;
            const q = this.modelSearchQuery.toLowerCase();
            return this.availableModels.filter(m =>
                m.id.toLowerCase().includes(q) || m.name.toLowerCase().includes(q)
            );
        },
        
        async loadScheduledTasks() {
            this.loading = true;
            try {
                const response = await this.apiFetch('/api/v1/schedules?limit=100');
                if (response.ok) {
                    const data = await response.json();
                    this.scheduledTasks = data.schedules || [];
                }
            } catch (error) {
                console.error('Failed to load scheduled tasks:', error);
            } finally {
                this.loading = false;
            }
        },
        
        async loadSystemStatus() {
            try {
                const response = await this.apiFetch('/api/v1/system/status');
                if (response.ok) {
                    const data = await response.json();
                    this.systemStatus = data;
                }
            } catch (error) {
                console.error('Failed to load system status:', error);
            }
        },
        
        async loadProviders() {
            try {
                const response = await this.apiFetch('/api/v1/providers');
                if (response.ok) {
                    const data = await response.json();
                    this.providers = data.providers || [];
                    
                    // Auto-select default provider only if no persisted selection
                    if (!this.newTask.providerId) {
                        const defaultProvider = this.providers.find(p => p.isDefault);
                        if (defaultProvider) {
                            this.newTask.providerId = defaultProvider.id;
                        }
                    }
                    
                    // Load models for the active provider
                    const activeProvider = this.getActiveProvider();
                    if (activeProvider) {
                        await this.loadModelsForProvider(activeProvider.id);
                    }
                }
            } catch (error) {
                console.error('Failed to load providers:', error);
            }
        },
        
        getActiveProvider() {
            const savedId = localStorage.getItem('hivecrew_provider_id');
            return (savedId && this.providers.find(p => p.id === savedId))
                || this.providers.find(p => p.isDefault)
                || this.providers[0]
                || null;
        },
        
        async loadModelsForProvider(providerId) {
            try {
                const response = await this.apiFetch(`/api/v1/providers/${providerId}/models`);
                if (response.ok) {
                    const data = await response.json();
                    this.availableModels = data.models || [];
                }
            } catch (error) {
                console.error('Failed to load models:', error);
            }
        },

        // -------------------------------------------------------------------
        // --- Auto-refresh --------------------------------------------------
        // -------------------------------------------------------------------

        startAutoRefresh() {
            this.stopAutoRefresh();
            
            // 1-second tick for elapsed time display
            this.now = Date.now();
            this.tickInterval = setInterval(() => {
                this.now = Date.now();
            }, 1000);
            
            // Recursive setTimeout for adaptive API refresh
            this.scheduleRefresh();
        },
        
        scheduleRefresh() {
            const delay = this.hasActiveTasks() ? 3000 : 15000;
            this.refreshTimer = setTimeout(async () => {
                await this.loadSystemStatus();
                if (this.view === 'tasks') {
                    await this.loadTasks();
                    if (this.selectedTask) {
                        await this.refreshSelectedTask();
                    }
                    // Check for pending questions/permissions on running tasks
                    if (!this.selectedTask && this.hasActiveTasks()) {
                        await this.checkPendingAlerts();
                    }
                } else if (this.view === 'scheduled') {
                    await this.loadScheduledTasks();
                    if (this.selectedSchedule) {
                        await this.refreshSelectedSchedule();
                    }
                }
                // Schedule next refresh (re-evaluates delay based on current state)
                this.scheduleRefresh();
            }, delay);
        },
        
        async refreshSelectedTask() {
            if (!this.selectedTask) return;
            try {
                const response = await this.apiFetch(`/api/v1/tasks/${this.selectedTask.id}`);
                if (response.ok) {
                    const wasActive = this.isActiveStatus(this.selectedTask?.status);
                    const oldPlan = this.selectedTask?.planMarkdown;
                    this.selectedTask = await response.json();
                    const isActive = this.isActiveStatus(this.selectedTask?.status);
                    
                    // Sync plan markdown if not actively editing
                    if (!this.planEditing) {
                        this.editedPlanMarkdown = this.selectedTask?.planMarkdown || '';
                    }
                    
                    // Start/stop screenshot polling and event stream on status change
                    if (!wasActive && isActive) {
                        this.startScreenshotPolling();
                        this.startEventStream(this.selectedTask.id);
                    } else if (wasActive && !isActive) {
                        this.stopScreenshotPolling();
                        this.stopEventStream();
                    }
                    
                    // Re-render Mermaid if plan changed
                    if (this.selectedTask?.planMarkdown && this.selectedTask.planMarkdown !== oldPlan) {
                        this.$nextTick(() => {
                            const planEl = document.querySelector('.plan-rendered');
                            this.renderMermaidDiagrams(planEl);
                        });
                    }
                }
            } catch (error) {
                console.error('Failed to refresh task:', error);
            }
        },
        
        async refreshSelectedSchedule() {
            if (!this.selectedSchedule) return;
            try {
                const response = await this.apiFetch(`/api/v1/schedules/${this.selectedSchedule.id}`);
                if (response.ok) {
                    this.selectedSchedule = await response.json();
                }
            } catch (error) {
                console.error('Failed to refresh schedule:', error);
            }
        },
        
        stopAutoRefresh() {
            if (this.refreshTimer) {
                clearTimeout(this.refreshTimer);
                this.refreshTimer = null;
            }
            if (this.tickInterval) {
                clearInterval(this.tickInterval);
                this.tickInterval = null;
            }
        },
        
        hasActiveTasks() {
            return this.tasks.some(t => ['running', 'queued', 'waiting_for_vm', 'planning', 'plan_review'].includes(t.status));
        },

        // -------------------------------------------------------------------
        // --- Quick Create --------------------------------------------------
        // -------------------------------------------------------------------

        saveQuickModelSelection() {
            if (this.quickModelId) {
                localStorage.setItem('hivecrew_model_id', this.quickModelId);
                this.newTask.modelId = this.quickModelId;
            }
        },
        
        selectModel(modelId) {
            this.quickModelId = modelId;
            this.modelDropdownOpen = false;
            this.modelSearchQuery = '';
            this.saveQuickModelSelection();
        },
        
        selectCustomModel() {
            const custom = this.modelSearchQuery.trim();
            if (custom) {
                this.quickModelId = custom;
                this.modelDropdownOpen = false;
                this.modelSearchQuery = '';
                this.saveQuickModelSelection();
            }
        },
        
        setQuickMode(planFirst) {
            this.quickPlanFirst = planFirst;
            localStorage.setItem('hivecrew_plan_first', planFirst ? 'true' : 'false');
        },
        
        async handleQuickFileSelect(event) {
            const files = await this.filterOutFolders(Array.from(event.target.files));
            if (files.length === 0 && event.target.files.length > 0) {
                this.showToast('Folders cannot be uploaded — please select individual files', 'error');
            }
            this.quickFiles = [...this.quickFiles, ...files];
            event.target.value = '';
        },
        
        async handlePromptDrop(event) {
            this.isDraggingFiles = false;
            const dt = event.dataTransfer;
            if (!dt || !dt.files || dt.files.length === 0) return;
            
            const files = await this.filterOutFolders(Array.from(dt.files));
            if (files.length === 0) {
                this.showToast('Folders cannot be uploaded — please select individual files', 'error');
                return;
            }
            this.quickFiles = [...this.quickFiles, ...files];
        },
        
        removeQuickFile(index) {
            this.quickFiles.splice(index, 1);
        },
        
        async quickCreateTask() {
            if (this.quickCreating) return;
            const description = this.quickTaskDescription.trim();
            if (!description) return;
            
            // Resolve provider: persisted → default → first available
            const savedProviderId = localStorage.getItem('hivecrew_provider_id');
            const provider = (savedProviderId && this.providers.find(p => p.id === savedProviderId))
                || this.providers.find(p => p.isDefault)
                || this.providers[0];
            
            if (!provider) {
                this.showToast('No providers configured. Add one in the Hivecrew app.', 'error');
                return;
            }
            
            const modelId = this.quickModelId.trim();
            if (!modelId) {
                this.showToast('Enter a model ID in the prompt bar.', 'error');
                return;
            }
            
            this.quickCreating = true;
            
            try {
                const providerName = provider.displayName || provider.id;
                let response;
                
                if (this.quickFiles.length > 0) {
                    const formData = new FormData();
                    formData.append('description', description);
                    formData.append('providerName', providerName);
                    formData.append('modelId', modelId);
                    if (this.quickPlanFirst) {
                        formData.append('planFirst', 'true');
                    }
                    for (const file of this.quickFiles) {
                        formData.append('files', file);
                    }
                    response = await this.apiFetch('/api/v1/tasks', {
                        method: 'POST',
                        body: formData
                    });
                } else {
                    response = await this.apiFetch('/api/v1/tasks', {
                        method: 'POST',
                        body: JSON.stringify({
                            description,
                            providerName,
                            modelId,
                            planFirst: this.quickPlanFirst
                        })
                    });
                }
                
                if (!response.ok) {
                    const errorData = await response.json();
                    throw new Error(errorData.error?.message || 'Failed to create task');
                }
                
                this.quickTaskDescription = '';
                this.quickFiles = [];
                this.showToast('Task created', 'success');
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.quickCreating = false;
            }
        },

        // -------------------------------------------------------------------
        // --- Task Create Modal ---------------------------------------------
        // -------------------------------------------------------------------

        openCreateModal() {
            this.showCreateModal = true;
            this.isScheduling = false;
            this.createError = '';
            this.creating = false;
            this.resetNewTask();
        },
        
        openScheduleModal() {
            this.showCreateModal = true;
            this.isScheduling = true;
            this.createError = '';
            this.creating = false;
            this.resetNewTask();
        },
        
        closeCreateModal() {
            this.showCreateModal = false;
            this.isScheduling = false;
            this.createError = '';
            this.creating = false;
        },
        
        async handleFileSelect(event) {
            const allFiles = Array.from(event.target.files);
            const files = await this.filterOutFolders(allFiles);
            if (files.length < allFiles.length) {
                this.showToast('Folders cannot be uploaded — please select individual files', 'error');
            }
            this.newTask.files = files;
        },
        
        removeFile(index) {
            this.newTask.files.splice(index, 1);
            // Update file input to reflect changes
            const fileInput = document.getElementById('task-files-input');
            if (fileInput) fileInput.value = '';
        },
        
        async filterOutFolders(files) {
            const validFiles = [];
            for (const file of files) {
                // Folders typically have size 0 and no type; verify by attempting to read
                if (file.size === 0 && !file.type) {
                    continue; // Almost certainly a folder entry
                }
                try {
                    // Attempt to read the first byte — this fails for directory entries
                    await file.slice(0, 1).arrayBuffer();
                    validFiles.push(file);
                } catch {
                    // Reading failed — this is a folder, skip it
                }
            }
            return validFiles;
        },
        
        resetNewTask() {
            const tomorrow = new Date();
            tomorrow.setDate(tomorrow.getDate() + 1);
            
            // Restore persisted selections or use defaults
            const savedProviderId = localStorage.getItem('hivecrew_provider_id');
            const savedModelId = localStorage.getItem('hivecrew_model_id');
            
            const defaultProviderId = (savedProviderId && this.providers.some(p => p.id === savedProviderId))
                ? savedProviderId
                : (this.providers.find(p => p.isDefault)?.id || '');
            
            this.newTask = {
                title: '',
                description: '',
                providerId: defaultProviderId,
                modelId: savedModelId || '',
                planFirst: false,
                isRecurring: false,
                scheduleDate: tomorrow.toISOString().split('T')[0],
                scheduleTime: '09:00',
                recurrenceType: 'weekly',
                daysOfWeek: [2], // Monday (1=Sunday, 2=Monday, etc.)
                dayOfMonth: 1,
                files: []
            };
            
            // Clear file input if it exists
            const fileInput = document.getElementById('task-files-input');
            if (fileInput) fileInput.value = '';
        },
        
        canCreateTask() {
            const can = !!(this.newTask.description.trim() && 
                   this.newTask.providerId && 
                   this.newTask.modelId);
            return can;
        },
        
        toggleDay(day) {
            const index = this.newTask.daysOfWeek.indexOf(day);
            if (index === -1) {
                this.newTask.daysOfWeek.push(day);
            } else if (this.newTask.daysOfWeek.length > 1) {
                this.newTask.daysOfWeek.splice(index, 1);
            }
        },
        
        async createTask() {
            if (this.creating) return;
            if (!this.canCreateTask()) {
                this.createError = 'Please fill in the description, provider, and model.';
                return;
            }
            
            this.creating = true;
            this.createError = '';
            
            try {
                // Find provider name
                const provider = this.providers.find(p => p.id === this.newTask.providerId);
                const providerName = provider?.displayName || this.newTask.providerId;
                
                if (this.isScheduling) {
                    await this._createScheduledTask(providerName);
                } else {
                    await this._createImmediateTask(providerName);
                }
                
            } catch (error) {
                console.error('[Hivecrew] Create task error:', error);
                this.createError = error.message || 'An unexpected error occurred';
            } finally {
                console.log('[Hivecrew] Create task finished, creating =', this.creating);
                this.creating = false;
            }
        },
        
        /** @private Create a scheduled task via /api/v1/schedules */
        async _createScheduledTask(providerName) {
            const [hours, minutes] = this.newTask.scheduleTime.split(':').map(Number);
            
            // Build schedule object
            const schedule = {};
            if (this.newTask.isRecurring) {
                schedule.recurrence = {
                    type: this.newTask.recurrenceType,
                    hour: hours,
                    minute: minutes
                };
                
                if (this.newTask.recurrenceType === 'weekly') {
                    schedule.recurrence.daysOfWeek = this.newTask.daysOfWeek;
                } else if (this.newTask.recurrenceType === 'monthly') {
                    schedule.recurrence.dayOfMonth = this.newTask.dayOfMonth;
                }
            } else {
                const scheduledAt = new Date(`${this.newTask.scheduleDate}T${this.newTask.scheduleTime}:00`);
                schedule.scheduledAt = scheduledAt.toISOString();
            }
            
            let response;
            
            if (this.newTask.files.length > 0) {
                const formData = new FormData();
                formData.append('title', this.newTask.title.trim() || this.newTask.description.trim().substring(0, 50));
                formData.append('description', this.newTask.description.trim());
                formData.append('providerName', providerName);
                formData.append('modelId', this.newTask.modelId);
                formData.append('schedule', JSON.stringify(schedule));
                
                for (const file of this.newTask.files) {
                    formData.append('files', file);
                }
                
                response = await this.apiFetch('/api/v1/schedules', {
                    method: 'POST',
                    body: formData
                });
            } else {
                const body = {
                    title: this.newTask.title.trim() || this.newTask.description.trim().substring(0, 50),
                    description: this.newTask.description.trim(),
                    providerName: providerName,
                    modelId: this.newTask.modelId,
                    schedule: schedule
                };
                
                response = await this.apiFetch('/api/v1/schedules', {
                    method: 'POST',
                    body: JSON.stringify(body)
                });
            }
            
            if (!response.ok) {
                const error = await response.json();
                throw new Error(error.error?.message || 'Failed to create schedule');
            }
            
            this.closeCreateModal();
            this.showToast('Task scheduled successfully', 'success');
            this.view = 'scheduled';
            await this.loadScheduledTasks();
        },
        
        /** @private Create an immediate task via /api/v1/tasks */
        async _createImmediateTask(providerName) {
            console.log('[Hivecrew] Creating immediate task...');
            
            const body = {
                description: this.newTask.description.trim(),
                providerName: providerName,
                modelId: this.newTask.modelId,
                planFirst: this.newTask.planFirst || false
            };
            
            let response;
            
            if (this.newTask.files.length > 0) {
                console.log('[Hivecrew] Using FormData for file upload');
                const formData = new FormData();
                formData.append('description', body.description);
                formData.append('providerName', body.providerName);
                formData.append('modelId', body.modelId);
                if (body.planFirst) {
                    formData.append('planFirst', 'true');
                }
                
                for (const file of this.newTask.files) {
                    formData.append('files', file);
                }
                
                response = await this.apiFetch('/api/v1/tasks', {
                    method: 'POST',
                    body: formData
                });
            } else {
                console.log('[Hivecrew] Sending JSON request:', body);
                response = await this.apiFetch('/api/v1/tasks', {
                    method: 'POST',
                    body: JSON.stringify(body)
                });
            }
            
            console.log('[Hivecrew] Response status:', response.status);
            
            if (!response.ok) {
                const errorData = await response.json();
                console.log('[Hivecrew] Error response:', errorData);
                throw new Error(errorData.error?.message || 'Failed to create task');
            }
            
            console.log('[Hivecrew] Task created successfully');
            this.closeCreateModal();
            this.showToast('Task created successfully', 'success');
            this.view = 'tasks';
            await this.loadTasks();
        },

        // -------------------------------------------------------------------
        // --- Task Detail ---------------------------------------------------
        // -------------------------------------------------------------------

        async openTaskDetail(task) {
            try {
                const response = await this.apiFetch(`/api/v1/tasks/${task.id}`);
                if (response.ok) {
                    this.selectedTask = await response.json();
                } else {
                    this.selectedTask = task;
                }
            } catch (error) {
                this.selectedTask = task;
            }
            // Initialize editing state
            this.editedPlanMarkdown = this.selectedTask?.planMarkdown || '';
            this.planEditing = false;
            this.answerText = '';
            
            // Start screenshot polling and event stream for active tasks
            if (this.isActiveStatus(this.selectedTask?.status)) {
                this.startScreenshotPolling();
                this.startEventStream(this.selectedTask.id);
            }
            
            // Render Mermaid diagrams after DOM update
            if (this.selectedTask?.planMarkdown) {
                this.$nextTick(() => {
                    const planEl = document.querySelector('.plan-rendered');
                    this.renderMermaidDiagrams(planEl);
                });
            }
        },
        
        closeTaskDetail() {
            this.selectedTask = null;
            this.stopScreenshotPolling();
            this.stopEventStream();
        },
        
        isActiveStatus(status) {
            return ['running', 'queued', 'waiting_for_vm'].includes(status);
        },
        
        isPlanReviewStatus(status) {
            return ['planning', 'plan_review'].includes(status);
        },
        
        startScreenshotPolling() {
            this.stopScreenshotPolling();
            this.refreshScreenshot();
            this.screenshotTimer = setInterval(() => {
                this.refreshScreenshot();
            }, 2000);
        },
        
        stopScreenshotPolling() {
            if (this.screenshotTimer) {
                clearInterval(this.screenshotTimer);
                this.screenshotTimer = null;
            }
            if (this.screenshotUrl) {
                URL.revokeObjectURL(this.screenshotUrl);
                this.screenshotUrl = '';
            }
        },
        
        async refreshScreenshot() {
            if (!this.selectedTask) return;
            try {
                const response = await this.apiFetch(
                    `/api/v1/tasks/${this.selectedTask.id}/screenshot`
                );
                if (response.ok) {
                    const blob = await response.blob();
                    const oldUrl = this.screenshotUrl;
                    this.screenshotUrl = URL.createObjectURL(blob);
                    if (oldUrl) URL.revokeObjectURL(oldUrl);
                }
            } catch (error) {
                // Silently ignore screenshot errors
            }
        },
        
        // -------------------------------------------------------------------
        // --- Event Stream (polling) ----------------------------------------
        // -------------------------------------------------------------------
        
        startEventStream(taskId) {
            this.stopEventStream();
            this.taskEvents = [];
            this.eventSince = 0;
            
            // Poll immediately, then every second
            this.pollActivity(taskId);
            this.eventTimer = setInterval(() => {
                this.pollActivity(taskId);
            }, 1000);
        },
        
        async pollActivity(taskId) {
            try {
                const response = await this.apiFetch(
                    `/api/v1/tasks/${taskId}/activity?since=${this.eventSince}`
                );
                if (response.ok) {
                    const data = await response.json();
                    if (data.events && data.events.length > 0) {
                        this.taskEvents.push(...data.events);
                        this.eventSince = data.total;
                        // Auto-scroll the event log
                        this.$nextTick(() => {
                            const log = document.querySelector('.event-log');
                            if (log) log.scrollTop = log.scrollHeight;
                        });
                    } else if (data.total !== undefined) {
                        this.eventSince = data.total;
                    }
                }
            } catch (error) {
                // Silently ignore polling errors
            }
        },
        
        stopEventStream() {
            if (this.eventTimer) {
                clearInterval(this.eventTimer);
                this.eventTimer = null;
            }
            this.taskEvents = [];
            this.eventSince = 0;
        },
        
        formatEventTime(timestamp) {
            if (!timestamp) return '';
            const d = new Date(timestamp);
            return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        },
        
        // -------------------------------------------------------------------
        // --- Markdown Rendering --------------------------------------------
        // -------------------------------------------------------------------
        
        renderMarkdown(md) {
            if (!md || typeof marked === 'undefined') return md || '';
            try {
                return marked.parse(md);
            } catch (e) {
                return md;
            }
        },
        
        async renderMermaidDiagrams(containerEl) {
            if (typeof mermaid === 'undefined' || !containerEl) return;
            const codeBlocks = containerEl.querySelectorAll('pre code.language-mermaid');
            for (const block of codeBlocks) {
                const pre = block.parentElement;
                const source = block.textContent;
                const id = 'mermaid-' + Math.random().toString(36).substring(2, 9);
                try {
                    const { svg } = await mermaid.render(id, source);
                    const div = document.createElement('div');
                    div.className = 'mermaid-diagram';
                    div.innerHTML = svg;
                    pre.replaceWith(div);
                } catch (e) {
                    // Leave the code block as-is if Mermaid can't render it
                }
            }
        },

        // -------------------------------------------------------------------
        // --- Schedule Detail -----------------------------------------------
        // -------------------------------------------------------------------

        async openScheduleDetail(schedule) {
            try {
                const response = await this.apiFetch(`/api/v1/schedules/${schedule.id}`);
                if (response.ok) {
                    this.selectedSchedule = await response.json();
                } else {
                    this.selectedSchedule = schedule;
                }
            } catch (error) {
                this.selectedSchedule = schedule;
            }
        },
        
        closeScheduleDetail() {
            this.selectedSchedule = null;
        },

        // -------------------------------------------------------------------
        // --- Task Actions --------------------------------------------------
        // -------------------------------------------------------------------

        async performAction(action, instructions = null) {
            if (!this.selectedTask) return;
            
            this.actionLoading = true;
            
            try {
                const body = { action };
                if (instructions) {
                    body.instructions = instructions;
                }
                
                const response = await this.apiFetch(`/api/v1/tasks/${this.selectedTask.id}`, {
                    method: 'PATCH',
                    body: JSON.stringify(body)
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || `Failed to ${action} task`);
                }
                
                const updatedTask = await response.json();
                this.selectedTask = updatedTask;
                
                this.showToast(`Task ${action}ed successfully`, 'success');
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async sendInstructions() {
            if (!this.instructionsText.trim()) return;
            const text = this.instructionsText.trim();
            this.instructionsText = '';
            await this.performAction('instruct', text);
        },
        
        async cancelTask() {
            if (!confirm('Are you sure you want to cancel this task?')) return;
            await this.performAction('cancel');
        },
        
        async pauseTask() {
            await this.performAction('pause');
        },
        
        async resumeTask() {
            await this.performAction('resume');
        },
        
        async approvePlan() {
            await this.performAction('approve_plan');
        },
        
        async savePlanEdits() {
            if (!this.selectedTask) return;
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(`/api/v1/tasks/${this.selectedTask.id}`, {
                    method: 'PATCH',
                    body: JSON.stringify({
                        action: 'edit_plan',
                        planMarkdown: this.editedPlanMarkdown
                    })
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to save plan edits');
                }
                
                const updatedTask = await response.json();
                this.selectedTask = updatedTask;
                this.planEditing = false;
                
                this.showToast('Plan updated and approved', 'success');
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async cancelPlan() {
            await this.performAction('cancel_plan');
        },
        
        async submitAnswer(answer) {
            if (!this.selectedTask?.pendingQuestion) return;
            
            const text = (answer || this.answerText || '').trim();
            if (!text) return;
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(
                    `/api/v1/tasks/${this.selectedTask.id}/question/answer`,
                    {
                        method: 'POST',
                        body: JSON.stringify({
                            questionId: this.selectedTask.pendingQuestion.id,
                            answer: text
                        })
                    }
                );
                
                if (!response.ok && response.status !== 204) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to submit answer');
                }
                
                this.answerText = '';
                this.showToast('Answer submitted', 'success');
                await this.refreshSelectedTask();
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async respondToPermission(approved) {
            if (!this.selectedTask?.pendingPermission) return;
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(
                    `/api/v1/tasks/${this.selectedTask.id}/permission/respond`,
                    {
                        method: 'POST',
                        body: JSON.stringify({
                            permissionId: this.selectedTask.pendingPermission.id,
                            approved: approved
                        })
                    }
                );
                
                if (!response.ok && response.status !== 204) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to respond to permission');
                }
                
                this.showToast(approved ? 'Permission granted' : 'Permission denied', 'success');
                await this.refreshSelectedTask();
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async approvePermission() {
            await this.respondToPermission(true);
        },
        
        async denyPermission() {
            await this.respondToPermission(false);
        },
        
        async rerunTask() {
            if (!this.selectedTask) return;
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(`/api/v1/tasks/${this.selectedTask.id}`, {
                    method: 'PATCH',
                    body: JSON.stringify({ action: 'rerun' })
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to rerun task');
                }
                
                this.showToast('Task restarted', 'success');
                this.closeTaskDetail();
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async deleteTask() {
            if (!this.selectedTask) return;
            
            if (!confirm('Are you sure you want to delete this task? This cannot be undone.')) {
                return;
            }
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(`/api/v1/tasks/${this.selectedTask.id}`, {
                    method: 'DELETE'
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to delete task');
                }
                
                this.showToast('Task deleted', 'success');
                this.closeTaskDetail();
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },

        // -------------------------------------------------------------------
        // --- Schedule Actions ----------------------------------------------
        // -------------------------------------------------------------------

        async runScheduleNow() {
            if (!this.selectedSchedule) return;
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(`/api/v1/schedules/${this.selectedSchedule.id}/run`, {
                    method: 'POST'
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to run schedule');
                }
                
                this.showToast('Task started', 'success');
                this.closeScheduleDetail();
                
                // Switch to tasks view and refresh
                this.view = 'tasks';
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async toggleSchedule() {
            if (!this.selectedSchedule) return;
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(`/api/v1/schedules/${this.selectedSchedule.id}`, {
                    method: 'PATCH',
                    body: JSON.stringify({
                        isEnabled: !this.selectedSchedule.isEnabled
                    })
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to update schedule');
                }
                
                const updatedSchedule = await response.json();
                this.selectedSchedule = updatedSchedule;
                
                this.showToast(`Schedule ${updatedSchedule.isEnabled ? 'enabled' : 'disabled'}`, 'success');
                await this.loadScheduledTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async deleteSchedule() {
            if (!this.selectedSchedule) return;
            
            if (!confirm('Are you sure you want to delete this scheduled task?')) {
                return;
            }
            
            this.actionLoading = true;
            
            try {
                const response = await this.apiFetch(`/api/v1/schedules/${this.selectedSchedule.id}`, {
                    method: 'DELETE'
                });
                
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error?.message || 'Failed to delete schedule');
                }
                
                this.showToast('Schedule deleted', 'success');
                this.closeScheduleDetail();
                await this.loadScheduledTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },

        // -------------------------------------------------------------------
        // --- File Downloads ------------------------------------------------
        // -------------------------------------------------------------------

        async downloadFile(taskId, filename, isInput = false) {
            try {
                const typeParam = isInput ? '?type=input' : '';
                const response = await this.apiFetch(
                    `/api/v1/tasks/${taskId}/files/${encodeURIComponent(filename)}${typeParam}`
                );
                
                if (!response.ok) {
                    throw new Error('Failed to download file');
                }
                
                // Get the blob from the response
                const blob = await response.blob();
                
                // Create a download link and trigger it
                const url = window.URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = filename;
                document.body.appendChild(a);
                a.click();
                
                // Cleanup
                window.URL.revokeObjectURL(url);
                document.body.removeChild(a);
                
            } catch (error) {
                this.showToast(`Download failed: ${error.message}`, 'error');
            }
        },

        // -------------------------------------------------------------------
        // --- Toast Notifications -------------------------------------------
        // -------------------------------------------------------------------

        showToast(message, type = 'info') {
            const id = ++this.toastId;
            this.toasts.push({ id, message, type, visible: true });
            
            // Auto-remove after 4 seconds
            setTimeout(() => {
                this.removeToast(id);
            }, 4000);
        },
        
        removeToast(id) {
            const index = this.toasts.findIndex(t => t.id === id);
            if (index !== -1) {
                this.toasts[index].visible = false;
                setTimeout(() => {
                    this.toasts = this.toasts.filter(t => t.id !== id);
                }, 300);
            }
        },

        // -------------------------------------------------------------------
        // --- Formatting Helpers --------------------------------------------
        // -------------------------------------------------------------------

        formatStatus(status) {
            if (!status) return '';
            
            const statusMap = {
                'queued': 'Queued',
                'waiting_for_vm': 'Starting',
                'running': 'Running',
                'paused': 'Paused',
                'completed': 'Completed',
                'failed': 'Failed',
                'cancelled': 'Cancelled',
                'timed_out': 'Timed Out',
                'max_iterations': 'Max Steps',
                'scheduled': 'Scheduled',
                'planning': 'Planning',
                'plan_review': 'Review Plan',
                'plan_failed': 'Plan Failed'
            };
            
            return statusMap[status] || status;
        },
        
        formatDate(dateString) {
            if (!dateString) return '';
            
            const date = new Date(dateString);
            const now = new Date();
            const diff = now - date;
            
            if (diff < 60000) return 'Just now';
            if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
            if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
            if (diff < 604800000) return `${Math.floor(diff / 86400000)}d ago`;
            
            return date.toLocaleDateString(undefined, {
                month: 'short',
                day: 'numeric'
            });
        },
        
        formatDateTime(dateString) {
            if (!dateString) return '';
            
            const date = new Date(dateString);
            return date.toLocaleString(undefined, {
                month: 'short',
                day: 'numeric',
                year: 'numeric',
                hour: 'numeric',
                minute: '2-digit'
            });
        },
        
        formatScheduledTime(schedule) {
            const dateStr = schedule.nextRunAt || schedule.scheduledAt;
            if (!dateStr) return '';
            
            const date = new Date(dateStr);
            const now = new Date();
            
            if (date.toDateString() === now.toDateString()) {
                return `Today at ${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`;
            }
            
            const tomorrow = new Date(now);
            tomorrow.setDate(tomorrow.getDate() + 1);
            if (date.toDateString() === tomorrow.toDateString()) {
                return `Tomorrow at ${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`;
            }
            
            return date.toLocaleString(undefined, {
                weekday: 'short',
                month: 'short',
                day: 'numeric',
                hour: 'numeric',
                minute: '2-digit'
            });
        },
        
        formatRecurrence(schedule) {
            if (!schedule.recurrence) return '';
            
            const r = schedule.recurrence;
            const time = this.formatTime(r.hour, r.minute);
            
            switch (r.type) {
                case 'daily':
                    return `Daily at ${time}`;
                case 'weekly':
                    const days = (r.daysOfWeek || []).map(d => {
                        const dayNames = ['', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
                        return dayNames[d] || '';
                    }).filter(Boolean).join(', ');
                    return `Every ${days} at ${time}`;
                case 'monthly':
                    const suffix = this.getOrdinalSuffix(r.dayOfMonth);
                    return `Monthly on the ${r.dayOfMonth}${suffix} at ${time}`;
                default:
                    return '';
            }
        },
        
        formatTime(hour, minute) {
            const h = hour % 12 || 12;
            const m = String(minute).padStart(2, '0');
            const ampm = hour < 12 ? 'AM' : 'PM';
            return `${h}:${m} ${ampm}`;
        },
        
        getOrdinalSuffix(n) {
            if (n >= 11 && n <= 13) return 'th';
            switch (n % 10) {
                case 1: return 'st';
                case 2: return 'nd';
                case 3: return 'rd';
                default: return 'th';
            }
        },
        
        formatDuration(seconds) {
            if (!seconds) return '';
            
            if (seconds < 60) return `${seconds}s`;
            
            const minutes = Math.floor(seconds / 60);
            const remainingSeconds = seconds % 60;
            
            if (minutes < 60) {
                return remainingSeconds > 0 ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`;
            }
            
            const hours = Math.floor(minutes / 60);
            const remainingMinutes = minutes % 60;
            
            return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}m` : `${hours}h`;
        },
        
        formatElapsed(dateString) {
            if (!dateString) return '';
            const seconds = Math.floor((this.now - new Date(dateString).getTime()) / 1000);
            if (seconds < 0) return '';
            if (seconds < 60) return `${seconds}s`;
            const minutes = Math.floor(seconds / 60);
            const secs = seconds % 60;
            if (minutes < 60) return `${minutes}m ${String(secs).padStart(2, '0')}s`;
            const hours = Math.floor(minutes / 60);
            const mins = minutes % 60;
            return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
        },
        
        formatFileSize(bytes) {
            if (!bytes) return '';
            
            if (bytes < 1024) return `${bytes} B`;
            if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
            return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
        }
    }));
});
