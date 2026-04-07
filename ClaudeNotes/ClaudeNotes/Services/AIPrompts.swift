import Foundation

enum AIPrompts {
    static let systemPrompt = """
    You are an AI assistant integrated into a note-taking application called ClaudeNotes. \
    Your role is to help users understand, expand on, and gain insights from their notes. \
    Always respond in the same language as the note content. \
    Always respond with valid JSON matching the requested schema. Do not include any text outside the JSON.
    """

    static func analyzeNote(content: String) -> String {
        """
        Analyze the following note and return a JSON object with exactly these fields:
        - "summary": A concise 2-3 sentence summary of the note's key points
        - "topics": An array of 3-5 related topics or keywords worth exploring further
        - "insights": 2-3 sentences of key observations, connections, or suggestions for the author

        Note content:
        ---
        \(content)
        ---
        """
    }

    static func expandNote(content: String) -> String {
        """
        Based on the following note, suggest additional content the author might want to add. \
        Return a JSON object with:
        - "suggestions": An array of 2-4 paragraph suggestions, each as a string
        - "questions": An array of 2-3 thought-provoking questions related to the content

        Note content:
        ---
        \(content)
        ---
        """
    }

    static func summarizeNote(content: String) -> String {
        """
        Provide a concise summary of the following note. \
        Return a JSON object with:
        - "summary": A clear, well-structured summary (3-5 sentences)
        - "keyPoints": An array of the main points as brief strings

        Note content:
        ---
        \(content)
        ---
        """
    }
}
