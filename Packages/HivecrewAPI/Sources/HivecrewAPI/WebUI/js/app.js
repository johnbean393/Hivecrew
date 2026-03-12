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
        quickProviderId: localStorage.getItem('hivecrew_provider_id') || '',
        quickModelId: localStorage.getItem('hivecrew_model_id') || '',
        quickCopyCount: (() => {
            const raw = Number.parseInt(localStorage.getItem('hivecrew_prompt_copy_count') || '1', 10);
            return Number.isFinite(raw) ? Math.min(8, Math.max(1, raw)) : 1;
        })(),
        quickUseMultipleModels: localStorage.getItem('hivecrew_use_multiple_prompt_models') === 'true',
        quickMultiModelSelections: [],
        copyCountOptions: [1, 2, 3, 4, 5, 6, 7, 8],
        quickReasoningEnabled: null,
        quickReasoningEffort: null,
        quickReasoningEffortTouched: false,
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
            reasoningEnabled: null,
            reasoningEffort: null,
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
        writebackReview: null,
        
        // Selected schedule (for detail view)
        selectedSchedule: null,
        
        // Providers & Models
        providers: [],
        availableModels: [],
        modelsByProviderId: {},
        quickModelOptions: [],
        quickReasoningKind: 'none',
        quickReasoningSupportedEfforts: [],
        quickReasoningDefaultEffort: null,
        quickReasoningDefaultEnabled: false,
        taskReasoningKind: 'none',
        taskReasoningSupportedEfforts: [],
        taskReasoningDefaultEffort: null,
        taskReasoningDefaultEnabled: false,
        taskReasoningEffortTouched: false,
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
        
        // Skills & @ Mentions
        skills: [],
        mentionedSkills: [],
        mentionQuery: null,
        mentionSuggestions: [],
        mentionSelectedIndex: 0,
        showMentionDropdown: false,
        
        // VM Provisioning (env vars & injected files for @ mentions)
        provisioningEnvVars: [],
        provisioningFiles: [],
        
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
            if (this.newTask.providerId) {
                this.quickProviderId = this.newTask.providerId;
                localStorage.setItem('hivecrew_provider_id', this.newTask.providerId);
            }
            if (this.newTask.modelId) {
                localStorage.setItem('hivecrew_model_id', this.newTask.modelId);
                this.quickModelId = this.newTask.modelId;
            }
            this.normalizeQuickSelection();
            this.syncTaskReasoningSelection();
            this.syncQuickReasoningSelection();
        },

        saveProviderSelection() {
            if (this.newTask.providerId) {
                localStorage.setItem('hivecrew_provider_id', this.newTask.providerId);
            }
            this.loadModelsForProvider(this.newTask.providerId);
        },
        
        restoreSelections() {
            const savedProviderId = localStorage.getItem('hivecrew_provider_id');
            const savedModelId = localStorage.getItem('hivecrew_model_id');
            const savedCopyCount = Number.parseInt(localStorage.getItem('hivecrew_prompt_copy_count') || '1', 10);
            const rawSelections = localStorage.getItem('hivecrew_prompt_model_selections');
            
            if (savedProviderId && this.providers.some(p => p.id === savedProviderId)) {
                this.newTask.providerId = savedProviderId;
                this.quickProviderId = savedProviderId;
            }
            
            if (savedModelId) {
                this.newTask.modelId = savedModelId;
                this.quickModelId = savedModelId;
            }
            this.quickCopyCount = this.normalizeCopyCount(savedCopyCount);
            this.quickUseMultipleModels = localStorage.getItem('hivecrew_use_multiple_prompt_models') === 'true';
            this.quickMultiModelSelections = this.parseQuickMultiModelSelections(rawSelections);
            this.normalizeQuickSelection();
            this.normalizeQuickMultiModelSelections();
            this.syncTaskReasoningSelection();
            this.syncQuickReasoningSelection();
        },

        normalizeCopyCount(value) {
            const parsed = Number.parseInt(value, 10);
            if (!Number.isFinite(parsed)) {
                return 1;
            }
            return Math.min(8, Math.max(1, parsed));
        },

        copyCountLabel(value) {
            return `×${this.normalizeCopyCount(value)}`;
        },

        parseQuickMultiModelSelections(rawSelections) {
            if (!rawSelections) {
                return [];
            }

            try {
                const decoded = JSON.parse(rawSelections);
                if (!Array.isArray(decoded)) {
                    return [];
                }
                return decoded
                    .map(selection => ({
                        providerId: typeof selection.providerId === 'string' ? selection.providerId.trim() : '',
                        modelId: typeof selection.modelId === 'string' ? selection.modelId.trim() : '',
                        copyCount: this.normalizeCopyCount(selection.copyCount),
                        reasoningEnabled: typeof selection.reasoningEnabled === 'boolean'
                            ? selection.reasoningEnabled
                            : null,
                        reasoningEffort: typeof selection.reasoningEffort === 'string'
                            ? selection.reasoningEffort.trim() || null
                            : null
                    }))
                    .filter(selection => selection.providerId && selection.modelId);
            } catch {
                return [];
            }
        },

        modelSelectionKey(providerId, modelId) {
            return `${providerId}::${modelId}`;
        },

        deduplicateQuickMultiModelSelections(selections) {
            const orderedKeys = [];
            const keyedSelections = new Map();

            for (const selection of selections) {
                const providerId = (selection.providerId || '').trim();
                const modelId = (selection.modelId || '').trim();
                if (!providerId || !modelId) {
                    continue;
                }

                const key = this.modelSelectionKey(providerId, modelId);
                if (!keyedSelections.has(key)) {
                    orderedKeys.push(key);
                }
                keyedSelections.set(key, {
                    providerId,
                    modelId,
                    copyCount: this.normalizeCopyCount(selection.copyCount),
                    reasoningEnabled: typeof selection.reasoningEnabled === 'boolean'
                        ? selection.reasoningEnabled
                        : null,
                    reasoningEffort: typeof selection.reasoningEffort === 'string'
                        ? selection.reasoningEffort.trim() || null
                        : null
                });
            }

            return orderedKeys.map(key => keyedSelections.get(key));
        },

        persistQuickMultiModelSelections() {
            const deduped = this.deduplicateQuickMultiModelSelections(this.quickMultiModelSelections);
            this.quickMultiModelSelections = deduped;
            localStorage.setItem('hivecrew_use_multiple_prompt_models', this.quickUseMultipleModels ? 'true' : 'false');
            localStorage.setItem('hivecrew_prompt_model_selections', JSON.stringify(deduped));
        },

        saveQuickCopyCount() {
            this.quickCopyCount = this.normalizeCopyCount(this.quickCopyCount);
            localStorage.setItem('hivecrew_prompt_copy_count', String(this.quickCopyCount));
        },

        setQuickUseMultipleModels(isEnabled) {
            const enabled = !!isEnabled;
            if (this.quickUseMultipleModels === enabled) {
                return;
            }

            this.quickUseMultipleModels = enabled;
            if (enabled) {
                this.quickMultiModelSelections = [];
            }
            this.persistQuickMultiModelSelections();
        },

        getQuickModelMetadata(providerId, modelId) {
            return (this.modelsByProviderId[providerId] || []).find(model => model.id === modelId) || null;
        },

        getQuickMultiModelSelection(providerId, modelId) {
            return this.quickMultiModelSelections.find(selection =>
                selection.providerId === providerId && selection.modelId === modelId
            ) || null;
        },

        quickMultiModelSelectionIndex(providerId, modelId) {
            return this.quickMultiModelSelections.findIndex(selection =>
                selection.providerId === providerId && selection.modelId === modelId
            );
        },

        normalizeQuickMultiModelSelections() {
            const deduped = this.deduplicateQuickMultiModelSelections(this.quickMultiModelSelections);
            const normalized = deduped.filter(selection => {
                if (!this.providers.some(provider => provider.id === selection.providerId)) {
                    return false;
                }
                return !!this.getQuickModelMetadata(selection.providerId, selection.modelId);
            }).map(selection => {
                const model = this.getQuickModelMetadata(selection.providerId, selection.modelId);
                const resolved = this.resolveReasoningSelection(
                    model?.reasoningCapability || this.emptyReasoningCapability(),
                    selection.reasoningEnabled,
                    selection.reasoningEffort
                );
                return {
                    ...selection,
                    copyCount: this.normalizeCopyCount(selection.copyCount),
                    reasoningEnabled: resolved.reasoningEnabled,
                    reasoningEffort: resolved.reasoningEffort
                };
            });

            if (JSON.stringify(normalized) !== JSON.stringify(this.quickMultiModelSelections)) {
                this.quickMultiModelSelections = normalized;
            }
            this.persistQuickMultiModelSelections();
        },

        persistQuickProviderAndModel(providerId = this.quickProviderId, modelId = this.quickModelId) {
            if (providerId) {
                this.quickProviderId = providerId;
                this.newTask.providerId = providerId;
                localStorage.setItem('hivecrew_provider_id', providerId);
            }
            if (modelId) {
                this.quickModelId = modelId;
                this.newTask.modelId = modelId;
                localStorage.setItem('hivecrew_model_id', modelId);
            }
            this.quickReasoningEnabled = null;
            this.quickReasoningEffort = null;
            this.quickReasoningEffortTouched = false;
            this.newTask.reasoningEnabled = null;
            this.newTask.reasoningEffort = null;
            this.taskReasoningEffortTouched = false;
            this.normalizeQuickSelection();
            this.syncTaskReasoningSelection();
            this.syncQuickReasoningSelection();
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
                this.loadSystemStatus(),
                this.loadSkills(),
                this.loadProvisioning()
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
            const orderedOptions = this.orderedQuickModelOptions();
            if (!this.modelSearchQuery.trim()) return orderedOptions;
            const q = this.modelSearchQuery.toLowerCase();
            return orderedOptions.filter(m =>
                m.id.toLowerCase().includes(q)
                || m.name.toLowerCase().includes(q)
                || m.providerDisplayName.toLowerCase().includes(q)
            );
        },

        get quickReasoningCapability() {
            const selectedModel = this.resolveQuickModelSelection();
            return selectedModel?.reasoningCapability || {
                kind: 'none',
                supportedEfforts: [],
                defaultEffort: null,
                defaultEnabled: false
            };
        },

        get taskReasoningCapability() {
            return this.getReasoningCapabilityForModel(this.newTask.providerId, this.newTask.modelId);
        },

        get quickModelDisplayValue() {
            if (this.quickUseMultipleModels) {
                if (this.quickMultiModelSelections.length === 0) {
                    return 'Select models';
                }
                if (this.quickMultiModelSelections.length === 1) {
                    return this.quickMultiModelSelections[0].modelId;
                }
                return this.quickMultiModelSelections.map(selection => selection.modelId).join(', ');
            }

            const selectedModel = this.resolveQuickModelSelection();
            return selectedModel?.id || this.quickModelId || 'Select model...';
        },

        get hasQuickExecutionTarget() {
            if (this.quickUseMultipleModels) {
                return this.quickMultiModelSelections.length > 0;
            }
            return !!this.quickModelId.trim();
        },

        orderedQuickModelOptions() {
            const options = [...this.quickModelOptions];

            if (this.quickUseMultipleModels) {
                const selectionOrder = this.quickMultiModelSelections.map(selection =>
                    this.modelSelectionKey(selection.providerId, selection.modelId)
                );
                const selectedKeys = new Set(selectionOrder);
                const selectedOptions = selectionOrder
                    .map(key => options.find(model =>
                        this.modelSelectionKey(model.providerId, model.id) === key
                    ))
                    .filter(Boolean);
                const unselectedOptions = options.filter(model =>
                    !selectedKeys.has(this.modelSelectionKey(model.providerId, model.id))
                );
                return [...selectedOptions, ...unselectedOptions];
            }

            const selectedKey = this.modelSelectionKey(this.quickProviderId, this.quickModelId);
            const selectedOption = options.find(model =>
                this.modelSelectionKey(model.providerId, model.id) === selectedKey
            );
            if (!selectedOption) {
                return options;
            }
            return [
                selectedOption,
                ...options.filter(model =>
                    this.modelSelectionKey(model.providerId, model.id) !== selectedKey
                )
            ];
        },

        findQuickModelMatches(modelId) {
            if (!modelId) {
                return [];
            }
            return this.quickModelOptions.filter(model => model.id === modelId);
        },

        choosePreferredQuickModelMatch(matches) {
            if (!matches.length) {
                return null;
            }

            const preferredProviderIds = [
                this.quickProviderId,
                this.newTask.modelId === this.quickModelId ? this.newTask.providerId : null,
                this.getDefaultProviderId()
            ].filter(Boolean);

            const preferredProviderRank = providerId => {
                const index = preferredProviderIds.indexOf(providerId);
                return index === -1 ? -1 : (preferredProviderIds.length - index);
            };

            const capabilityRank = model => {
                const capability = model.reasoningCapability || {};
                switch (capability.kind) {
                    case 'effort':
                        return 300
                            + (capability.defaultEffort ? 40 : 0)
                            + ((capability.supportedEfforts || []).includes('medium') ? 10 : 0);
                    case 'toggle':
                        return 200;
                    default:
                        return 100;
                }
            };

            return [...matches].sort((left, right) => {
                const capabilityDelta = capabilityRank(right) - capabilityRank(left);
                if (capabilityDelta !== 0) {
                    return capabilityDelta;
                }

                const providerDelta = preferredProviderRank(right.providerId) - preferredProviderRank(left.providerId);
                if (providerDelta !== 0) {
                    return providerDelta;
                }

                return left.optionKey.localeCompare(right.optionKey);
            })[0] || null;
        },

        getQuickModelOption(providerId, modelId) {
            if (!modelId) {
                return null;
            }
            if (providerId) {
                return this.quickModelOptions.find(model =>
                    model.providerId === providerId && model.id === modelId
                ) || null;
            }
            const matches = this.quickModelOptions.filter(model => model.id === modelId);
            return matches.length === 1 ? matches[0] : null;
        },

        resolveQuickModelSelection() {
            if (!this.quickModelId) {
                return null;
            }

            const matches = this.findQuickModelMatches(this.quickModelId);
            return this.choosePreferredQuickModelMatch(matches);
        },

        rebuildQuickModelOptions() {
            this.quickModelOptions = this.providers.flatMap(provider =>
                (this.modelsByProviderId[provider.id] || []).map(model => ({
                    ...model,
                    providerId: provider.id,
                    providerDisplayName: provider.displayName || provider.id,
                    optionKey: `${provider.id}::${model.id}`
                }))
            );
        },

        getReasoningCapabilityForModel(providerId, modelId) {
            const matched = providerId
                ? (this.modelsByProviderId[providerId] || []).find(model => model.id === modelId)
                : this.getQuickModelOption(null, modelId);
            return matched?.reasoningCapability || {
                kind: 'none',
                supportedEfforts: [],
                defaultEffort: null,
                defaultEnabled: false
            };
        },

        getDefaultProviderId() {
            const savedProviderId = localStorage.getItem('hivecrew_provider_id');
            if (savedProviderId && this.providers.some(provider => provider.id === savedProviderId)) {
                return savedProviderId;
            }
            return this.providers.find(provider => provider.isDefault)?.id || this.providers[0]?.id || '';
        },

        emptyReasoningCapability() {
            return {
                kind: 'none',
                supportedEfforts: [],
                defaultEffort: null,
                defaultEnabled: false
            };
        },

        updateQuickReasoningCapability() {
            const selectedModel = this.resolveQuickModelSelection();
            const capability = selectedModel?.reasoningCapability || this.emptyReasoningCapability();
            this.quickReasoningKind = capability.kind || 'none';
            this.quickReasoningSupportedEfforts = capability.supportedEfforts || [];
            this.quickReasoningDefaultEffort = capability.defaultEffort ?? null;
            this.quickReasoningDefaultEnabled = capability.defaultEnabled ?? false;
        },

        updateTaskReasoningCapability() {
            const capability = this.getReasoningCapabilityForModel(
                this.newTask.providerId,
                this.newTask.modelId
            );
            this.taskReasoningKind = capability.kind || 'none';
            this.taskReasoningSupportedEfforts = capability.supportedEfforts || [];
            this.taskReasoningDefaultEffort = capability.defaultEffort ?? null;
            this.taskReasoningDefaultEnabled = capability.defaultEnabled ?? false;
        },

        normalizeQuickSelection() {
            if (!this.providers.length) {
                return;
            }

            if (!this.quickProviderId || !this.providers.some(provider => provider.id === this.quickProviderId)) {
                this.quickProviderId = this.getDefaultProviderId();
            }

            if (!this.quickModelId) {
                return;
            }

            const resolvedModel = this.resolveQuickModelSelection();
            if (resolvedModel) {
                this.quickProviderId = resolvedModel.providerId;
            }
            this.normalizeQuickMultiModelSelections();
        },

        preferredReasoningEffortDefault(capability) {
            const supportedEfforts = capability?.supportedEfforts || [];
            if (!supportedEfforts.length) {
                return null;
            }
            if (supportedEfforts.includes('high')) {
                return 'high';
            }
            if (capability?.defaultEffort && supportedEfforts.includes(capability.defaultEffort)) {
                return capability.defaultEffort;
            }
            return supportedEfforts[0] || null;
        },

        resolveReasoningSelection(capability, reasoningEnabled, reasoningEffort, preserveEffortSelection = false) {
            switch (capability?.kind) {
                case 'toggle':
                    return {
                        reasoningEnabled: reasoningEnabled ?? capability.defaultEnabled ?? false,
                        reasoningEffort: null
                    };
                case 'effort': {
                    const supportedEfforts = capability.supportedEfforts || [];
                    const fallbackEffort = this.preferredReasoningEffortDefault(capability);
                    const resolvedEffort = preserveEffortSelection && supportedEfforts.includes(reasoningEffort)
                        ? reasoningEffort
                        : fallbackEffort;
                    return {
                        reasoningEnabled: null,
                        reasoningEffort: resolvedEffort
                    };
                }
                default:
                    return { reasoningEnabled: null, reasoningEffort: null };
            }
        },

        formatReasoningEffortLabel(effort) {
            const normalized = (effort || '').trim().toLowerCase();
            if (normalized === 'xhigh') {
                return 'Extra High';
            }
            return normalized
                .replaceAll('_', ' ')
                .replace(/\b\w/g, character => character.toUpperCase());
        },

        syncTaskReasoningSelection() {
            this.updateTaskReasoningCapability();
            const resolved = this.resolveReasoningSelection(
                {
                    kind: this.taskReasoningKind,
                    supportedEfforts: this.taskReasoningSupportedEfforts,
                    defaultEffort: this.taskReasoningDefaultEffort,
                    defaultEnabled: this.taskReasoningDefaultEnabled
                },
                this.newTask.reasoningEnabled,
                this.newTask.reasoningEffort,
                this.taskReasoningEffortTouched
            );
            this.newTask.reasoningEnabled = resolved.reasoningEnabled;
            this.newTask.reasoningEffort = resolved.reasoningEffort;
        },

        syncQuickReasoningSelection() {
            this.updateQuickReasoningCapability();
            const resolved = this.resolveReasoningSelection(
                {
                    kind: this.quickReasoningKind,
                    supportedEfforts: this.quickReasoningSupportedEfforts,
                    defaultEffort: this.quickReasoningDefaultEffort,
                    defaultEnabled: this.quickReasoningDefaultEnabled
                },
                this.quickReasoningEnabled,
                this.quickReasoningEffort,
                this.quickReasoningEffortTouched
            );
            this.quickReasoningEnabled = resolved.reasoningEnabled;
            this.quickReasoningEffort = resolved.reasoningEffort;
        },

        quickResolvedReasoningEffort() {
            return this.resolveReasoningSelection(
                {
                    kind: this.quickReasoningKind,
                    supportedEfforts: this.quickReasoningSupportedEfforts,
                    defaultEffort: this.quickReasoningDefaultEffort,
                    defaultEnabled: this.quickReasoningDefaultEnabled
                },
                this.quickReasoningEnabled,
                this.quickReasoningEffort,
                this.quickReasoningEffortTouched
            ).reasoningEffort;
        },

        taskResolvedReasoningEffort() {
            return this.resolveReasoningSelection(
                {
                    kind: this.taskReasoningKind,
                    supportedEfforts: this.taskReasoningSupportedEfforts,
                    defaultEffort: this.taskReasoningDefaultEffort,
                    defaultEnabled: this.taskReasoningDefaultEnabled
                },
                this.newTask.reasoningEnabled,
                this.newTask.reasoningEffort,
                this.taskReasoningEffortTouched
            ).reasoningEffort;
        },

        isQuickModelSelected(model) {
            if (this.quickUseMultipleModels) {
                return this.quickMultiModelSelectionIndex(model.providerId, model.id) !== -1;
            }
            return this.quickProviderId === model.providerId && this.quickModelId === model.id;
        },

        selectQuickMultiModel(model) {
            const index = this.quickMultiModelSelectionIndex(model.providerId, model.id);
            this.persistQuickProviderAndModel(model.providerId, model.id);

            if (index >= 0) {
                this.quickMultiModelSelections.splice(index, 1);
                this.persistQuickMultiModelSelections();
                return;
            }

            const resolved = this.resolveReasoningSelection(
                model.reasoningCapability || this.emptyReasoningCapability(),
                null,
                null
            );
            this.quickMultiModelSelections = [
                ...this.quickMultiModelSelections,
                {
                    providerId: model.providerId,
                    modelId: model.id,
                    copyCount: this.normalizeCopyCount(this.quickCopyCount),
                    reasoningEnabled: resolved.reasoningEnabled,
                    reasoningEffort: resolved.reasoningEffort
                }
            ];
            this.persistQuickMultiModelSelections();
        },

        updateQuickMultiModelCopyCount(providerId, modelId, value) {
            const index = this.quickMultiModelSelectionIndex(providerId, modelId);
            if (index === -1) {
                return;
            }
            this.quickMultiModelSelections[index].copyCount = this.normalizeCopyCount(value);
            this.persistQuickMultiModelSelections();
        },

        updateQuickMultiModelReasoning(providerId, modelId, updates) {
            const index = this.quickMultiModelSelectionIndex(providerId, modelId);
            const model = this.getQuickModelMetadata(providerId, modelId);
            if (index === -1 || !model) {
                return;
            }
            const resolved = this.resolveReasoningSelection(
                model.reasoningCapability || this.emptyReasoningCapability(),
                Object.prototype.hasOwnProperty.call(updates, 'reasoningEnabled')
                    ? updates.reasoningEnabled
                    : this.quickMultiModelSelections[index].reasoningEnabled,
                Object.prototype.hasOwnProperty.call(updates, 'reasoningEffort')
                    ? updates.reasoningEffort
                    : this.quickMultiModelSelections[index].reasoningEffort
            );
            this.quickMultiModelSelections[index].reasoningEnabled = resolved.reasoningEnabled;
            this.quickMultiModelSelections[index].reasoningEffort = resolved.reasoningEffort;
            this.persistQuickMultiModelSelections();
        },

        resolvedQuickExecutionTargets() {
            if (this.quickUseMultipleModels) {
                return this.deduplicateQuickMultiModelSelections(this.quickMultiModelSelections)
                    .filter(selection => selection.providerId && selection.modelId)
                    .map(selection => ({
                        providerId: selection.providerId,
                        modelId: selection.modelId,
                        copyCount: this.normalizeCopyCount(selection.copyCount),
                        reasoningEnabled: selection.reasoningEnabled,
                        reasoningEffort: selection.reasoningEffort
                    }));
            }

            const modelId = this.quickModelId.trim();
            const providerId = this.quickProviderId || this.getDefaultProviderId();
            if (!providerId || !modelId) {
                return [];
            }

            return [{
                providerId,
                modelId,
                copyCount: this.normalizeCopyCount(this.quickCopyCount),
                reasoningEnabled: this.quickReasoningEnabled,
                reasoningEffort: this.quickReasoningEffort
            }];
        },

        quickSubmissionTaskCount() {
            return this.resolvedQuickExecutionTargets().reduce((total, target) =>
                total + this.normalizeCopyCount(target.copyCount), 0
            );
        },

        // -------------------------------------------------------------------
        // --- Skills & @ Mentions -------------------------------------------
        // -------------------------------------------------------------------

        async loadSkills() {
            try {
                const response = await this.apiFetch('/api/v1/skills');
                if (response.ok) {
                    const data = await response.json();
                    this.skills = (data.skills || []).filter(s => s.isEnabled);
                }
            } catch (error) {
                console.error('Failed to load skills:', error);
            }
        },

        async loadProvisioning() {
            try {
                const response = await this.apiFetch('/api/v1/provisioning');
                if (response.ok) {
                    const data = await response.json();
                    this.provisioningEnvVars = data.environmentVariables || [];
                    this.provisioningFiles = data.injectedFiles || [];
                }
            } catch (error) {
                console.error('Failed to load provisioning:', error);
            }
        },

        /**
         * Get the text content from the contentEditable prompt, reading
         * inline mention chips as their @name form.
         */
        getPromptText() {
            const el = this.$refs.promptTextarea;
            if (!el) return '';
            let text = '';
            for (const node of el.childNodes) {
                if (node.nodeType === Node.TEXT_NODE) {
                    text += node.textContent;
                } else if (node.nodeType === Node.ELEMENT_NODE) {
                    if (node.hasAttribute('data-mention')) {
                        const mentionType = node.getAttribute('data-mention-type');
                        const mentionName = node.getAttribute('data-mention');
                        if (mentionType === 'envvar') {
                            // Resolve env var mention to $KEY
                            text += '$' + mentionName;
                        } else if (mentionType === 'injectedfile') {
                            // Resolve injected file to its guest VM path
                            const guestPath = node.getAttribute('data-guest-path') || '';
                            if (guestPath) {
                                const expanded = guestPath
                                    .replace(/^~\//, '/Users/hivecrew/')
                                    .replace(/^\$HOME\//, '/Users/hivecrew/');
                                text += '"' + expanded + '"';
                            } else {
                                text += mentionName;
                            }
                        } else {
                            text += '@' + mentionName;
                        }
                    } else if (node.tagName === 'BR') {
                        text += '\n';
                    } else {
                        text += node.textContent;
                    }
                }
            }
            return text;
        },

        /**
         * Sync quickTaskDescription from the contentEditable div.
         * Called on every input event.
         */
        syncPromptText() {
            this.quickTaskDescription = this.getPromptText();

            // Sync mentionedSkills from what's actually in the DOM (only skill type)
            const el = this.$refs.promptTextarea;
            if (!el) return;
            const chips = el.querySelectorAll('[data-mention-type="skill"]');
            const current = new Set();
            chips.forEach(c => current.add(c.getAttribute('data-mention')));
            this.mentionedSkills = [...current];
        },

        /**
         * Handle input events on the contentEditable prompt.
         * Detects @ mentions and shows the suggestion dropdown.
         */
        handlePromptInput(event) {
            this.syncPromptText();

            const sel = window.getSelection();
            if (!sel.rangeCount) { this.showMentionDropdown = false; return; }

            const range = sel.getRangeAt(0);
            // Only look for @ in text nodes (not inside mention chips)
            const textNode = range.startContainer;
            if (textNode.nodeType !== Node.TEXT_NODE) {
                this.showMentionDropdown = false;
                this.mentionQuery = null;
                return;
            }

            const text = textNode.textContent;
            const cursorOffset = range.startOffset;

            // Scan backwards from cursor to find @
            let atIndex = -1;
            for (let i = cursorOffset - 1; i >= 0; i--) {
                const ch = text[i];
                if (ch === '@') {
                    if (i === 0 || /\s/.test(text[i - 1])) {
                        atIndex = i;
                    }
                    break;
                }
                if (/\s/.test(ch)) break;
            }

            if (atIndex >= 0) {
                const query = text.substring(atIndex + 1, cursorOffset).toLowerCase();
                this.mentionQuery = query;
                this._mentionTextNode = textNode;
                this._mentionAtIndex = atIndex;
                this.computeMentionSuggestions(query);
                this.showMentionDropdown = this.mentionSuggestions.length > 0;
                this.mentionSelectedIndex = 0;
            } else {
                this.showMentionDropdown = false;
                this.mentionQuery = null;
            }
        },

        computeMentionSuggestions(query) {
            const suggestions = [];

            // Add skills
            for (const skill of this.skills) {
                if (this.mentionedSkills.includes(skill.name)) continue;
                if (!query || skill.name.toLowerCase().includes(query) || skill.description.toLowerCase().includes(query)) {
                    suggestions.push({
                        type: 'skill',
                        name: skill.name,
                        description: skill.description,
                        display: skill.name
                    });
                }
            }

            // Add attached files
            for (const file of this.quickFiles) {
                const fileName = file.name.toLowerCase();
                if (!query || fileName.includes(query)) {
                    suggestions.push({
                        type: 'file',
                        name: file.name,
                        description: this.formatFileSize(file.size),
                        display: file.name
                    });
                }
            }

            // Add environment variables
            for (const envVar of this.provisioningEnvVars) {
                if (!query || envVar.key.toLowerCase().includes(query)) {
                    suggestions.push({
                        type: 'envvar',
                        name: envVar.key,
                        description: 'Environment Variable',
                        display: envVar.key
                    });
                }
            }

            // Add injected files
            for (const injFile of this.provisioningFiles) {
                const fileName = injFile.fileName.toLowerCase();
                const guestPath = (injFile.guestPath || '').toLowerCase();
                if (!query || fileName.includes(query) || guestPath.includes(query)) {
                    suggestions.push({
                        type: 'injectedfile',
                        name: injFile.fileName,
                        description: injFile.guestPath || 'No VM path set',
                        display: injFile.fileName,
                        guestPath: injFile.guestPath
                    });
                }
            }

            this.mentionSuggestions = suggestions.slice(0, 10);
        },

        handlePromptKeydown(event) {
            if (!this.showMentionDropdown) return;

            if (event.key === 'ArrowDown') {
                event.preventDefault();
                this.mentionSelectedIndex = Math.min(
                    this.mentionSelectedIndex + 1,
                    this.mentionSuggestions.length - 1
                );
            } else if (event.key === 'ArrowUp') {
                event.preventDefault();
                this.mentionSelectedIndex = Math.max(this.mentionSelectedIndex - 1, 0);
            } else if (event.key === 'Enter' || event.key === 'Tab') {
                if (this.mentionSuggestions.length > 0) {
                    event.preventDefault();
                    event.stopPropagation();
                    this.selectMention(this.mentionSuggestions[this.mentionSelectedIndex]);
                }
            } else if (event.key === 'Escape') {
                event.preventDefault();
                this.showMentionDropdown = false;
                this.mentionQuery = null;
            }
        },

        /**
         * Create an inline mention chip element.
         */
        _createMentionChip(type, name, extraData) {
            const chip = document.createElement('span');
            chip.setAttribute('data-mention', name);
            chip.setAttribute('data-mention-type', type);
            chip.setAttribute('contenteditable', 'false');
            chip.className = 'inline-mention inline-mention-' + type;

            // Store extra data for resolution
            if (extraData) {
                if (extraData.guestPath) chip.setAttribute('data-guest-path', extraData.guestPath);
            }

            if (type === 'skill') {
                chip.innerHTML =
                    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="11" height="11">' +
                    '<path d="M12 2l2.4 7.4H22l-6 4.6 2.3 7L12 16.4 5.7 21l2.3-7L2 9.4h7.6z"></path>' +
                    '</svg>' +
                    '<span>' + name + '</span>';
            } else if (type === 'envvar') {
                chip.innerHTML =
                    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="11" height="11">' +
                    '<polyline points="4 17 10 11 4 5"></polyline>' +
                    '<line x1="12" y1="19" x2="20" y2="19"></line>' +
                    '</svg>' +
                    '<span>$' + name + '</span>';
            } else if (type === 'injectedfile') {
                chip.innerHTML =
                    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="11" height="11">' +
                    '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>' +
                    '<polyline points="14 2 14 8 20 8"></polyline>' +
                    '<line x1="16" y1="13" x2="8" y2="13"></line>' +
                    '<line x1="16" y1="17" x2="8" y2="17"></line>' +
                    '</svg>' +
                    '<span>' + name + '</span>';
            } else {
                chip.innerHTML =
                    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="11" height="11">' +
                    '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>' +
                    '<polyline points="14 2 14 8 20 8"></polyline>' +
                    '</svg>' +
                    '<span>' + name + '</span>';
            }
            return chip;
        },

        selectMention(item) {
            const el = this.$refs.promptTextarea;
            if (!el) return;

            const textNode = this._mentionTextNode;
            const atIndex = this._mentionAtIndex;
            if (!textNode || atIndex == null || textNode.nodeType !== Node.TEXT_NODE) return;

            const text = textNode.textContent;
            const sel = window.getSelection();
            const cursorOffset = sel.rangeCount ? sel.getRangeAt(0).startOffset : text.length;

            // Split text: before @, after query
            const before = text.substring(0, atIndex);
            const after = text.substring(cursorOffset);

            // Create mention chip with extra data
            const extraData = {};
            if (item.guestPath) extraData.guestPath = item.guestPath;
            const chip = this._createMentionChip(item.type, item.name, extraData);

            // Replace textNode content: set to "before", insert chip + space after
            textNode.textContent = before;
            const afterNode = document.createTextNode('\u00A0' + after); // non-breaking space to ensure cursor lands after chip
            const parent = textNode.parentNode;
            parent.insertBefore(chip, textNode.nextSibling);
            parent.insertBefore(afterNode, chip.nextSibling);

            // Track mentioned skill
            if (item.type === 'skill' && !this.mentionedSkills.includes(item.name)) {
                this.mentionedSkills.push(item.name);
            }

            // Close dropdown
            this.showMentionDropdown = false;
            this.mentionQuery = null;
            this._mentionTextNode = null;
            this._mentionAtIndex = null;

            // Place cursor after the chip
            this.$nextTick(() => {
                el.focus();
                const range = document.createRange();
                range.setStart(afterNode, 1); // after the nbsp
                range.collapse(true);
                sel.removeAllRanges();
                sel.addRange(range);
                this.syncPromptText();
            });
        },

        /**
         * Clear the contentEditable prompt.
         */
        clearPrompt() {
            const el = this.$refs.promptTextarea;
            if (el) el.innerHTML = '';
            this.quickTaskDescription = '';
            this.mentionedSkills = [];
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
                    this.rebuildQuickModelOptions();
                    
                    // Auto-select default provider only if no persisted selection
                    if (!this.newTask.providerId) {
                        const defaultProvider = this.providers.find(p => p.isDefault);
                        if (defaultProvider) {
                            this.newTask.providerId = defaultProvider.id;
                        }
                    }

                    if (!this.quickProviderId) {
                        this.quickProviderId = this.getDefaultProviderId();
                    }
                    
                    await this.loadAllProviderModels();
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
        
        async fetchModelsForProvider(providerId) {
            if (!providerId) {
                return [];
            }
            try {
                const response = await this.apiFetch(`/api/v1/providers/${providerId}/models`);
                if (response.ok) {
                    const data = await response.json();
                    const models = data.models || [];
                    this.modelsByProviderId = {
                        ...this.modelsByProviderId,
                        [providerId]: models
                    };
                    this.rebuildQuickModelOptions();
                    return models;
                }
            } catch (error) {
                console.error('Failed to load models:', error);
            }
            return this.modelsByProviderId[providerId] || [];
        },

        async loadAllProviderModels() {
            await Promise.all(this.providers.map(provider => this.fetchModelsForProvider(provider.id)));
            await this.loadModelsForProvider(this.newTask.providerId || this.getDefaultProviderId());
            this.normalizeQuickSelection();
            this.syncQuickReasoningSelection();
        },

        async loadModelsForProvider(providerId) {
            const models = await this.fetchModelsForProvider(providerId);
            this.availableModels = models;
            if (this.newTask.providerId === providerId && this.newTask.modelId && !models.some(model => model.id === this.newTask.modelId)) {
                this.newTask.modelId = '';
            }
            this.normalizeQuickSelection();
            this.syncTaskReasoningSelection();
            this.syncQuickReasoningSelection();
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
            this.persistQuickProviderAndModel(this.quickProviderId, this.quickModelId);
            if (this.quickProviderId) {
                this.loadModelsForProvider(this.quickProviderId);
            }
        },
        
        selectModel(model) {
            this.quickProviderId = model.providerId;
            this.quickModelId = model.id;
            this.modelDropdownOpen = false;
            this.modelSearchQuery = '';
            this.saveQuickModelSelection();
        },
        
        selectCustomModel() {
            if (this.quickUseMultipleModels) {
                return;
            }
            const custom = this.modelSearchQuery.trim();
            if (custom) {
                if (!this.quickProviderId) {
                    this.quickProviderId = this.getDefaultProviderId();
                }
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
            const description = this.getPromptText().trim();
            if (!description) return;

            this.normalizeQuickSelection();
            const executionTargets = this.resolvedQuickExecutionTargets();
            if (executionTargets.length === 0) {
                this.showToast(
                    this.quickUseMultipleModels
                        ? 'Select at least one model in the prompt bar.'
                        : 'Enter a model ID in the prompt bar.',
                    'error'
                );
                return;
            }

            if (!this.providers.length) {
                this.showToast('No providers configured. Add one in the Hivecrew app.', 'error');
                return;
            }

            this.quickCreating = true;
            
            try {
                let response;
                const payload = {
                    description,
                    planFirst: this.quickPlanFirst,
                    targets: executionTargets.map(target => ({
                        providerId: target.providerId,
                        modelId: target.modelId,
                        copyCount: this.normalizeCopyCount(target.copyCount),
                        reasoningEnabled: target.reasoningEnabled,
                        reasoningEffort: target.reasoningEffort
                    }))
                };
                if (this.mentionedSkills.length > 0) {
                    payload.mentionedSkillNames = this.mentionedSkills;
                }

                if (this.quickFiles.length > 0) {
                    const formData = new FormData();
                    formData.append('description', description);
                    formData.append('targets', JSON.stringify(payload.targets));
                    if (this.quickPlanFirst) {
                        formData.append('planFirst', 'true');
                    }
                    for (const skillName of this.mentionedSkills) {
                        formData.append('mentionedSkillNames', skillName);
                    }
                    for (const file of this.quickFiles) {
                        formData.append('files', file);
                    }
                    response = await this.apiFetch('/api/v1/tasks/batch', {
                        method: 'POST',
                        body: formData
                    });
                } else {
                    response = await this.apiFetch('/api/v1/tasks/batch', {
                        method: 'POST',
                        body: JSON.stringify(payload)
                    });
                }
                
                if (!response.ok) {
                    const errorData = await response.json();
                    throw new Error(errorData.error?.message || 'Failed to create task');
                }

                const data = await response.json();
                const createdCount = Array.isArray(data.tasks) ? data.tasks.length : this.quickSubmissionTaskCount();
                const modelCount = executionTargets.length;
                this.clearPrompt();
                this.quickFiles = [];
                if (!this.quickUseMultipleModels) {
                    this.quickCopyCount = 1;
                    this.saveQuickCopyCount();
                }
                this.showToast(
                    createdCount === 1
                        ? 'Task created'
                        : `Created ${createdCount} tasks across ${modelCount} model${modelCount === 1 ? '' : 's'}`,
                    'success'
                );
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
                reasoningEnabled: null,
                reasoningEffort: null,
                planFirst: false,
                isRecurring: false,
                scheduleDate: tomorrow.toISOString().split('T')[0],
                scheduleTime: '09:00',
                recurrenceType: 'weekly',
                daysOfWeek: [2], // Monday (1=Sunday, 2=Monday, etc.)
                dayOfMonth: 1,
                files: []
            };
            this.taskReasoningEffortTouched = false;
            if (defaultProviderId) {
                this.loadModelsForProvider(defaultProviderId);
            } else {
                this.syncTaskReasoningSelection();
            }
            
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
                if (this.newTask.reasoningEnabled !== null) {
                    formData.append('reasoningEnabled', this.newTask.reasoningEnabled ? 'true' : 'false');
                }
                if (this.newTask.reasoningEffort) {
                    formData.append('reasoningEffort', this.newTask.reasoningEffort);
                }
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
                    reasoningEnabled: this.newTask.reasoningEnabled,
                    reasoningEffort: this.newTask.reasoningEffort,
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
                reasoningEnabled: this.newTask.reasoningEnabled,
                reasoningEffort: this.newTask.reasoningEffort,
                planFirst: this.newTask.planFirst || false
            };
            
            let response;
            
            if (this.newTask.files.length > 0) {
                console.log('[Hivecrew] Using FormData for file upload');
                const formData = new FormData();
                formData.append('description', body.description);
                formData.append('providerName', body.providerName);
                formData.append('modelId', body.modelId);
                if (body.reasoningEnabled !== null) {
                    formData.append('reasoningEnabled', body.reasoningEnabled ? 'true' : 'false');
                }
                if (body.reasoningEffort) {
                    formData.append('reasoningEffort', body.reasoningEffort);
                }
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
            this.writebackReview = null;
            this.answerText = '';
            
            // Start screenshot polling and event stream for active tasks
            if (this.isActiveStatus(this.selectedTask?.status)) {
                this.startScreenshotPolling();
                this.startEventStream(this.selectedTask.id);
            }

            if (this.selectedTask?.status === 'writeback_review') {
                await this.loadWritebackReview(this.selectedTask.id);
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
            this.writebackReview = null;
            this.stopScreenshotPolling();
            this.stopEventStream();
        },
        
        isActiveStatus(status) {
            return ['running', 'queued', 'waiting_for_vm'].includes(status);
        },
        
        isPlanReviewStatus(status) {
            return ['planning', 'plan_review'].includes(status);
        },

        async loadWritebackReview(taskId) {
            this.writebackReview = null;
            try {
                const response = await this.apiFetch(`/api/v1/tasks/${taskId}/writeback`);
                if (response.status === 204) {
                    return;
                }
                if (response.ok) {
                    this.writebackReview = await response.json();
                }
            } catch (error) {
                // Silently ignore review loading errors
            }
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

                if (this.selectedTask?.status === 'writeback_review') {
                    await this.loadWritebackReview(this.selectedTask.id);
                } else {
                    this.writebackReview = null;
                }
                
                this.showToast(this.actionSuccessMessage(action), 'success');
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

        async approveWriteback() {
            await this.performAction('approve_writeback');
        },

        async discardWriteback() {
            await this.performAction('discard_writeback');
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
                'plan_failed': 'Plan Failed',
                'writeback_review': 'Review Changes'
            };
            
            return statusMap[status] || status;
        },

        actionSuccessMessage(action) {
            const messages = {
                'cancel': 'Task cancelled',
                'pause': 'Task paused',
                'resume': 'Task resumed',
                'rerun': 'Task rerun started',
                'instruct': 'Instructions sent',
                'approve_plan': 'Plan approved',
                'edit_plan': 'Plan updated and approved',
                'cancel_plan': 'Planning cancelled',
                'approve_writeback': 'Local changes applied',
                'discard_writeback': 'Staged changes discarded'
            };
            return messages[action] || 'Task updated';
        },

        formatWritebackOperation(operation) {
            const labels = {
                'copy': 'Copy',
                'move': 'Move',
                'replace_file': 'Replace File'
            };
            return labels[operation] || operation;
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
