import AppKit
import SwiftUI

extension PromptTextEditor {
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor
        var isProgrammaticUpdate = false
        weak var textView: NSTextView?
        var currentMentionRange: NSRange?

        init(_ parent: PromptTextEditor) {
            self.parent = parent
        }

        var onFileDrop: ((URL) -> Void)? {
            parent.onFileDrop
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if textView.hasMarkedText() { return }
            if isProgrammaticUpdate {
                isProgrammaticUpdate = false
                return
            }

            let newString = textView.string
            let cursor = textView.selectedRange.location
            withAnimation(.linear) {
                parent.text = newString
                parent.insertionPoint = cursor
            }
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
            checkForMentionQuery(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if isProgrammaticUpdate {
                isProgrammaticUpdate = false
                return
            }

            let cursor = textView.selectedRange.location
            if parent.insertionPoint != cursor {
                parent.insertionPoint = cursor
            }
            checkForMentionQuery(in: textView)
        }

        func insertMention(suggestion: MentionSuggestion, at range: NSRange, in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }

            isProgrammaticUpdate = true

            let attachment: MentionTextAttachment
            switch suggestion.type {
            case .task:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    referencedTaskId: suggestion.taskId ?? suggestion.id
                )
            case .skill:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    skillName: suggestion.skillName ?? suggestion.displayName
                )
            case .attachment, .deliverable:
                guard let url = suggestion.url else { return }
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    fileURL: url
                )
            case .environmentVariable:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    envKey: suggestion.displayName,
                    envValue: suggestion.detail ?? ""
                )
            case .injectedFile:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    guestPath: suggestion.detail ?? "",
                    assetFileURL: suggestion.url
                )
            }

            let attachmentString = NSAttributedString(attachment: attachment)
            let spaceString = NSAttributedString(string: " ", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ])

            let combinedString = NSMutableAttributedString()
            combinedString.append(attachmentString)
            combinedString.append(spaceString)

            textStorage.replaceCharacters(in: range, with: combinedString)

            let newCursorPosition = range.location + combinedString.length
            textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))

            var typingAttrs = textView.typingAttributes
            typingAttrs[.foregroundColor] = NSColor.labelColor
            typingAttrs.removeValue(forKey: .attachment)
            textView.typingAttributes = typingAttrs

            parent.text = textView.string
            parent.insertionPoint = newCursorPosition
            currentMentionRange = nil
            parent.onMentionQuery?(nil, nil)

            textView.invalidateIntrinsicContentSize()
        }

        private func checkForMentionQuery(in textView: NSTextView) {
            let text = textView.string
            let cursorLocation = textView.selectedRange.location

            guard cursorLocation > 0, cursorLocation <= text.count else {
                currentMentionRange = nil
                parent.onMentionQuery?(nil, nil)
                return
            }

            let textBeforeCursor = String(text.prefix(cursorLocation))
            guard let atIndex = textBeforeCursor.lastIndex(of: "@") else {
                currentMentionRange = nil
                parent.onMentionQuery?(nil, nil)
                return
            }

            let atPosition = textBeforeCursor.distance(from: textBeforeCursor.startIndex, to: atIndex)
            if atPosition > 0 {
                let charBeforeAt = textBeforeCursor[textBeforeCursor.index(before: atIndex)]
                if !charBeforeAt.isWhitespace && !charBeforeAt.isNewline {
                    currentMentionRange = nil
                    parent.onMentionQuery?(nil, nil)
                    return
                }
            }

            let queryStartIndex = textBeforeCursor.index(after: atIndex)
            let queryText = String(textBeforeCursor[queryStartIndex...])
            if queryText.contains(" ") || queryText.contains("\n") {
                currentMentionRange = nil
                parent.onMentionQuery?(nil, nil)
                return
            }

            let mentionRange = NSRange(location: atPosition, length: queryText.count + 1)
            currentMentionRange = mentionRange

            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let window = textView.window else {
                parent.onMentionQuery?(nil, nil)
                return
            }

            let nsRange = NSRange(location: cursorLocation, length: 0)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            boundingRect.origin.x += textView.textContainerInset.width
            boundingRect.origin.y += textView.textContainerInset.height

            let pointInTextView = CGPoint(x: boundingRect.origin.x, y: boundingRect.origin.y + boundingRect.height)
            let pointInWindow = textView.convert(pointInTextView, to: nil)
            let screenPoint = window.convertPoint(toScreen: pointInWindow)

            let mentionQuery = MentionQuery(
                query: queryText,
                range: mentionRange,
                position: pointInTextView
            )
            parent.onMentionQuery?(mentionQuery, screenPoint)
        }
    }
}
