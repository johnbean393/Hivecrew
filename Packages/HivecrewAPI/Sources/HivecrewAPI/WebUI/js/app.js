/**
 * Hivecrew Web UI - Alpine.js Application
 */

console.log('[Hivecrew] app.js loaded');

// Register the main Alpine.js component
document.addEventListener('alpine:init', () => {
    console.log('[Hivecrew] Alpine initializing...');
    Alpine.data('hivecrew', () => ({
        // Authentication
        apiKey: localStorage.getItem('hivecrew_api_key') || '',
        apiKeyInput: '',
        authError: '',
        
        // Navigation
        view: 'tasks',
        
        // Tasks
        tasks: [],
        scheduledTasks: [],
        selectedTask: null,
        loading: false,
        statusFilter: '',
        
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
            isRecurring: false,
            scheduleDate: '',
            scheduleTime: '09:00',
            recurrenceType: 'weekly',
            daysOfWeek: [2], // 1=Sunday, 2=Monday, etc.
            dayOfMonth: 1,
            files: [] // Supports both immediate and scheduled tasks
        },
        
        // Selected schedule (for detail view)
        selectedSchedule: null,
        
        // Providers & Models
        providers: [],
        
        // Task Actions
        actionLoading: false,
        
        // Toasts
        toasts: [],
        toastId: 0,
        
        // Auto-refresh
        refreshInterval: null,
        
        // Initialize
        async init() {
            console.log('[Hivecrew] Component init() called, apiKey:', this.apiKey ? 'present' : 'missing');
            this.creating = false;
            if (this.apiKey) {
                await this.loadInitialData();
                this.startAutoRefresh();
                
                // Restore persisted selections
                this.restoreSelections();
            }
            
            // Set default schedule date to tomorrow
            const tomorrow = new Date();
            tomorrow.setDate(tomorrow.getDate() + 1);
            this.newTask.scheduleDate = tomorrow.toISOString().split('T')[0];
            console.log('[Hivecrew] Component init() complete');
        },
        
        // Persist model selection
        saveModelSelection() {
            if (this.newTask.modelId) {
                localStorage.setItem('hivecrew_model_id', this.newTask.modelId);
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
            }
        },
        
        // Authentication
        async saveApiKey() {
            if (!this.apiKeyInput) return;
            
            this.authError = '';
            
            // Test the API key
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
                
                // Load initial data
                await this.loadInitialData();
                this.startAutoRefresh();
                
            } catch (error) {
                this.authError = 'Connection failed. Please check the server is running.';
            }
        },
        
        logout() {
            this.apiKey = '';
            localStorage.removeItem('hivecrew_api_key');
            this.stopAutoRefresh();
            this.tasks = [];
            this.scheduledTasks = [];
            this.providers = [];
            this.models = [];
        },
        
        // API Helpers
        async apiFetch(endpoint, options = {}) {
            console.log('[Hivecrew] apiFetch:', options.method || 'GET', endpoint);
            
            const response = await fetch(endpoint, {
                ...options,
                headers: {
                    'Authorization': `Bearer ${this.apiKey}`,
                    'Content-Type': 'application/json',
                    ...options.headers
                }
            });
            
            console.log('[Hivecrew] apiFetch response:', response.status, endpoint);
            
            if (response.status === 401) {
                this.logout();
                this.authError = 'Session expired. Please log in again.';
                throw new Error('Unauthorized');
            }
            
            return response;
        },
        
        // Data Loading
        async loadInitialData() {
            await Promise.all([
                this.loadTasks(),
                this.loadProviders()
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
                }
            } catch (error) {
                console.error('Failed to load providers:', error);
            }
        },
        
        // Auto-refresh
        startAutoRefresh() {
            this.stopAutoRefresh();
            this.refreshInterval = setInterval(async () => {
                // Refresh the current view's list
                if (this.view === 'tasks') {
                    await this.loadTasks();
                    // Also refresh selected task details if viewing one
                    if (this.selectedTask) {
                        await this.refreshSelectedTask();
                    }
                } else if (this.view === 'scheduled') {
                    await this.loadScheduledTasks();
                    // Also refresh selected schedule details if viewing one
                    if (this.selectedSchedule) {
                        await this.refreshSelectedSchedule();
                    }
                }
            }, 10000); // Refresh every 10 seconds
        },
        
        // Refresh selected task without closing the modal
        async refreshSelectedTask() {
            if (!this.selectedTask) return;
            try {
                const response = await fetch(`/api/v1/tasks/${this.selectedTask.id}`, {
                    headers: { 'Authorization': `Bearer ${this.apiKey}` }
                });
                if (response.ok) {
                    const data = await response.json();
                    this.selectedTask = data.task;
                }
            } catch (error) {
                console.error('Failed to refresh task:', error);
            }
        },
        
        // Refresh selected schedule without closing the modal
        async refreshSelectedSchedule() {
            if (!this.selectedSchedule) return;
            try {
                const response = await fetch(`/api/v1/schedules/${this.selectedSchedule.id}`, {
                    headers: { 'Authorization': `Bearer ${this.apiKey}` }
                });
                if (response.ok) {
                    const data = await response.json();
                    this.selectedSchedule = data.schedule;
                }
            } catch (error) {
                console.error('Failed to refresh schedule:', error);
            }
        },
        
        stopAutoRefresh() {
            if (this.refreshInterval) {
                clearInterval(this.refreshInterval);
                this.refreshInterval = null;
            }
        },
        
        // Create Task Modal
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
        
        // File handling for task creation
        handleFileSelect(event) {
            const files = Array.from(event.target.files);
            this.newTask.files = files;
        },
        
        removeFile(index) {
            this.newTask.files.splice(index, 1);
            // Update file input to reflect changes
            const fileInput = document.getElementById('task-files-input');
            if (fileInput) fileInput.value = '';
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
                    // Create a scheduled task via /api/v1/schedules
                    const [hours, minutes] = this.newTask.scheduleTime.split(':').map(Number);
                    
                    // Build schedule object
                    const schedule = {};
                    if (this.newTask.isRecurring) {
                        // Recurring schedule
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
                        // One-time schedule
                        const scheduledAt = new Date(`${this.newTask.scheduleDate}T${this.newTask.scheduleTime}:00`);
                        schedule.scheduledAt = scheduledAt.toISOString();
                    }
                    
                    let response;
                    
                    if (this.newTask.files.length > 0) {
                        // Use FormData for file uploads
                        const formData = new FormData();
                        formData.append('title', this.newTask.title.trim() || this.newTask.description.trim().substring(0, 50));
                        formData.append('description', this.newTask.description.trim());
                        formData.append('providerName', providerName);
                        formData.append('modelId', this.newTask.modelId);
                        formData.append('schedule', JSON.stringify(schedule));
                        
                        for (const file of this.newTask.files) {
                            formData.append('files', file);
                        }
                        
                        response = await fetch('/api/v1/schedules', {
                            method: 'POST',
                            headers: {
                                'Authorization': `Bearer ${this.apiKey}`
                            },
                            body: formData
                        });
                    } else {
                        // Regular JSON request
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
                } else {
                    // Create an immediate task via /api/v1/tasks
                    console.log('[Hivecrew] Creating immediate task...');
                    
                    const body = {
                        description: this.newTask.description.trim(),
                        providerName: providerName,
                        modelId: this.newTask.modelId
                    };
                    
                    let response;
                    
                    if (this.newTask.files.length > 0) {
                        // Use FormData for file uploads
                        console.log('[Hivecrew] Using FormData for file upload');
                        const formData = new FormData();
                        formData.append('description', body.description);
                        formData.append('providerName', body.providerName);
                        formData.append('modelId', body.modelId);
                        
                        for (const file of this.newTask.files) {
                            formData.append('files', file);
                        }
                        
                        response = await fetch('/api/v1/tasks', {
                            method: 'POST',
                            headers: {
                                'Authorization': `Bearer ${this.apiKey}`
                            },
                            body: formData
                        });
                    } else {
                        // Regular JSON request
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
                }
                
            } catch (error) {
                console.error('[Hivecrew] Create task error:', error);
                this.createError = error.message || 'An unexpected error occurred';
            } finally {
                console.log('[Hivecrew] Create task finished, creating =', this.creating);
                this.creating = false;
            }
        },
        
        // Task Detail
        async openTaskDetail(task) {
            // Load full task details
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
        },
        
        // Schedule Detail
        async openScheduleDetail(schedule) {
            // Load full schedule details
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
        
        closeTaskDetail() {
            this.selectedTask = null;
        },
        
        closeScheduleDetail() {
            this.selectedSchedule = null;
        },
        
        // Task Actions
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
                
                // Refresh task list
                await this.loadTasks();
                
            } catch (error) {
                this.showToast(error.message, 'error');
            } finally {
                this.actionLoading = false;
            }
        },
        
        async cancelTask() {
            await this.performAction('cancel');
        },
        
        async pauseTask() {
            await this.performAction('pause');
        },
        
        async resumeTask() {
            await this.performAction('resume');
        },
        
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
        
        // File Downloads
        async downloadFile(taskId, filename, isInput = false) {
            try {
                const typeParam = isInput ? '?type=input' : '';
                const response = await fetch(`/api/v1/tasks/${taskId}/files/${encodeURIComponent(filename)}${typeParam}`, {
                    headers: {
                        'Authorization': `Bearer ${this.apiKey}`
                    }
                });
                
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
        
        // Toast Notifications
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
        
        // Formatting Helpers
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
                'scheduled': 'Scheduled'
            };
            
            return statusMap[status] || status;
        },
        
        formatDate(dateString) {
            if (!dateString) return '';
            
            const date = new Date(dateString);
            const now = new Date();
            const diff = now - date;
            
            // Less than a minute
            if (diff < 60000) {
                return 'Just now';
            }
            
            // Less than an hour
            if (diff < 3600000) {
                const minutes = Math.floor(diff / 60000);
                return `${minutes}m ago`;
            }
            
            // Less than a day
            if (diff < 86400000) {
                const hours = Math.floor(diff / 3600000);
                return `${hours}h ago`;
            }
            
            // Less than a week
            if (diff < 604800000) {
                const days = Math.floor(diff / 86400000);
                return `${days}d ago`;
            }
            
            // Otherwise show date
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
            // Use nextRunAt for scheduled tasks
            const dateStr = schedule.nextRunAt || schedule.scheduledAt;
            if (!dateStr) return '';
            
            const date = new Date(dateStr);
            const now = new Date();
            
            // If today
            if (date.toDateString() === now.toDateString()) {
                return `Today at ${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`;
            }
            
            // If tomorrow
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
            
            if (seconds < 60) {
                return `${seconds}s`;
            }
            
            const minutes = Math.floor(seconds / 60);
            const remainingSeconds = seconds % 60;
            
            if (minutes < 60) {
                return remainingSeconds > 0 ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`;
            }
            
            const hours = Math.floor(minutes / 60);
            const remainingMinutes = minutes % 60;
            
            return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}m` : `${hours}h`;
        },
        
        formatFileSize(bytes) {
            if (!bytes) return '';
            
            if (bytes < 1024) {
                return `${bytes} B`;
            }
            
            if (bytes < 1024 * 1024) {
                return `${(bytes / 1024).toFixed(1)} KB`;
            }
            
            return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
        }
    }));
});
