import SwiftUI
import SwiftData
import TipKit
import UniformTypeIdentifiers
import HivecrewShared
import HivecrewLLM

extension ScheduleCreationSheet {
    // MARK: - Header

    var header: some View {
        HStack {
            Text(isEditing ? "Edit Schedule" : "Schedule Task")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Prompt Section

    var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should the agent do?")
                .font(.subheadline)
                .fontWeight(.medium)

            TextEditor(text: $taskDescription)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 80)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    // MARK: - File Attachment Section

    var fileAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.caption)
                        Text("Add Files")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if attachedFilePaths.isEmpty {
                Text("No files attached. Files will be available in the agent's inbox when the task runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFilePaths, id: \.self) { filePath in
                            ScheduleAttachmentItem(
                                filePath: filePath,
                                onRemove: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        attachedFilePaths.removeAll { $0 == filePath }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let path = url.path
                    if !attachedFilePaths.contains(path) {
                        attachedFilePaths.append(path)
                    }
                }
            }
        }
    }

    // MARK: - Skills Section

    var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skills")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    showSkillPicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                        Text("Add Skills")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showSkillPicker, arrowEdge: .bottom) {
                    skillPickerPopover
                }
            }

            if mentionedSkillNames.isEmpty {
                Text("No skills selected. The agent will auto-select relevant skills based on the task.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionedSkillNames, id: \.self) { skillName in
                            ScheduleSkillChip(
                                skillName: skillName,
                                onRemove: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        mentionedSkillNames.removeAll { $0 == skillName }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    var skillPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Select Skills")
                    .font(.headline)
                Spacer()
                Button {
                    showSkillPicker = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            if skillManager.skills.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No skills available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Import skills from the Skills window")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(skillManager.skills) { skill in
                            SkillPickerRow(
                                skill: skill,
                                isSelected: mentionedSkillNames.contains(skill.name),
                                onToggle: {
                                    toggleSkill(skill.name)
                                }
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 280)
    }

    // MARK: - Schedule Section

    var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When should it run?")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("", selection: $scheduleType) {
                Text("Recurring").tag(ScheduleType.recurring)
                Text("One-time").tag(ScheduleType.oneTime)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            if scheduleType == .oneTime {
                oneTimeConfig
            } else {
                recurringConfig
            }
        }
    }

    var oneTimeConfig: some View {
        HStack(spacing: 12) {
            datePickerButton

            Text("at")
                .foregroundStyle(.secondary)

            timePickerView
        }
        .padding(.top, 4)
    }

    var datePickerButton: some View {
        Button {
            showDatePicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                Text(formattedDate)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
            DatePicker("", selection: $scheduledDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
        }
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: scheduledDate)
    }

    var recurringConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $recurrenceFrequency) {
                    Text("Daily").tag(RecurrenceFrequency.daily)
                    Text("Weekly").tag(RecurrenceFrequency.weekly)
                    Text("Monthly").tag(RecurrenceFrequency.monthly)
                }
                .labelsHidden()
                .fixedSize()

                if recurrenceFrequency == .monthly {
                    Text("on the")
                        .foregroundStyle(.secondary)

                    Picker("", selection: $dayOfMonth) {
                        ForEach(1...31, id: \.self) { day in
                            Text(ordinal(day)).tag(day)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text("at")
                    .foregroundStyle(.secondary)

                timePickerView
            }

            if recurrenceFrequency == .weekly {
                weekdayPicker
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption)
                Text(schedulePreviewText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    func ordinal(_ day: Int) -> String {
        let suffix: String
        switch day {
        case 1, 21, 31: suffix = "st"
        case 2, 22: suffix = "nd"
        case 3, 23: suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    var timePickerView: some View {
        HStack(spacing: 4) {
            Picker("", selection: $scheduleHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%d", hour)).tag(hour)
                }
            }
            .labelsHidden()
            .fixedSize()

            Text(":")
                .foregroundStyle(.primary)
                .fontWeight(.medium)

            Picker("", selection: $scheduleMinute) {
                ForEach(0..<60, id: \.self) { minute in
                    Text(String(format: "%02d", minute)).tag(minute)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(Array(zip(1...7, Calendar.current.veryShortWeekdaySymbols)), id: \.0) { day, label in
                Button {
                    toggleDay(day)
                } label: {
                    Text(label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 28, height: 28)
                        .background(selectedDaysOfWeek.contains(day) ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .foregroundColor(selectedDaysOfWeek.contains(day) ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    func toggleDay(_ day: Int) {
        if selectedDaysOfWeek.contains(day) {
            if selectedDaysOfWeek.count > 1 {
                selectedDaysOfWeek.remove(day)
            }
        } else {
            selectedDaysOfWeek.insert(day)
        }
    }

}
