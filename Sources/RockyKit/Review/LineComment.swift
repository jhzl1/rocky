import Foundation
import Observation

/// A comment on a diff's lines as it goes to a conversation (`CMT-05`): what the user wrote, the lines its chip shows,
/// and the text the agent gets (`ReviewPrompt.single`). The prompt is built when the comment is written, so a queued
/// comment keeps the code as it was then, whatever the agent's turn changes in the file meanwhile.
public struct LineComment: Equatable, Sendable {
    /// The comment itself: the transcript's text. A `PromptAttachment.marker` in it is where one of `files` sits.
    public let text: String
    public let range: LineRangeAttachment
    /// What the agent receives, as one text block.
    public let prompt: String
    /// Files attached next to the chip in the message box (`CMT-05`'s Resend), which go as links after the block and
    /// show as badges in the comment. The comment box attaches none.
    public let files: [URL]

    public init(text: String, range: LineRangeAttachment, prompt: String, files: [URL] = []) {
        self.text = text
        self.range = range
        self.prompt = prompt
        self.files = files
    }
}

/// Where `AppModel.sendLineComment` left a comment (`CMT-05`): sent, in the queue of the turn that runs, or nowhere
/// (the conversation is closed, or its agent could not start).
public enum LineCommentOutcome: Equatable, Sendable {
    case sent, queued, unavailable
}

/// A diff tab's comment box (`CMT-02`): the lines it is on, the text written so far, and the conversation it goes to.
/// `AppModel` keeps it while its tab is open, so a tab switch or Diff | Edit brings the box back. A class, so the box
/// and the rows observe its parts apart: typing redraws the box, not the diff.
@MainActor
@Observable
public final class CommentDraft {
    public private(set) var side: CommentLine.Side
    public private(set) var start: Int
    public private(set) var end: Int
    public var text = ""
    /// The conversation picked in the box's "Sending to" menu; nil sends to the one the workspace shows
    /// (`AppModel.commentConversation(for:workspaceId:)`).
    public var conversationId: String?

    init(side: CommentLine.Side, lines: ClosedRange<Int>) {
        self.side = side
        self.start = lines.lowerBound
        self.end = lines.upperBound
    }

    /// The range's last line: the box opens under its row.
    public var lastLine: CommentLine {
        CommentLine(side: side, number: end)
    }

    public var lines: ClosedRange<Int> {
        start...end
    }

    public func contains(_ line: CommentLine) -> Bool {
        line.side == side && line.number >= start && line.number <= end
    }

    /// Another range of the same file: the text and the conversation stay, as in the mock.
    func move(side: CommentLine.Side, lines: ClosedRange<Int>) {
        if self.side != side { self.side = side }
        if start != lines.lowerBound { start = lines.lowerBound }
        if end != lines.upperBound { end = lines.upperBound }
    }
}
