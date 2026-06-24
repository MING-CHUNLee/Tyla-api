# frozen_string_literal: true

module Tyla
  module Values
    # Single source of truth for the tutor's native tool_use definitions.
    # Extracted from RunTutorChat (MS3 plan §7.1) so the per-persona tool whitelist
    # (PersonaProfile, built by TutorPersonaResolver) and the mini-loop draw from the
    # SAME schemas instead of duplicating them. The `name` of each tool doubles as the
    # action-channel whitelist key used to gate both the native and prose channels
    # (§7.3): edit_file / execute_script / load_file / load_reference.
    module TutorTools
      LOAD_REFERENCE = 'load_reference'

      EDIT_FILE = {
        name: 'edit_file',
        description: 'Apply a search-replace patch to a file the student has ALREADY loaded — one shown ' \
                     'in the "Student Workspace (live)" section with a "N| " line-number prefix on every line. ' \
                     'Set `start_line` to the line number shown on the first line you are replacing, and put ' \
                     'plain code (no "N| " prefix) in `search` and `replace`. ' \
                     'Do NOT call this for a file that appears only in the "Student Workspace (overview)" ' \
                     'section, is not shown at all, or was merely pasted into the chat: call load_file first ' \
                     'and wait for its numbered contents. Never invent a "N| " prefix or guess a line number.',
        input_schema: {
          type: 'object',
          properties: {
            path:    { type: 'string', description: 'Relative path to the file' },
            patches: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  start_line: { type: 'integer',
                                description: '1-based file line number of the first line of `search`, read ' \
                                             'from the "N| " prefix shown in the workspace context.' },
                  search:     { type: 'string',
                                description: 'The exact lines to find, as plain code WITHOUT the "N| " ' \
                                             'prefixes — copy the content only; put the line number in ' \
                                             '`start_line`.' },
                  replace:    { type: 'string', description: 'Replacement code WITHOUT line-number prefixes.' }
                },
                required: %w[start_line search replace]
              }
            }
          },
          required: %w[path patches]
        }
      }.freeze

      EXECUTE_SCRIPT = {
        name: 'execute_script',
        description: 'Provide a read-only R demo script. Use when showing runnable example code ' \
                     'that does not exist in any workspace file. No file writes or package installs.',
        input_schema: {
          type: 'object',
          properties: {
            code: { type: 'string', description: 'R code to execute' }
          },
          required: %w[code]
        }
      }.freeze

      LOAD_FILE = {
        name: 'load_file',
        description: 'Request the line-numbered contents of a workspace file that is not yet loaded ' \
                     '(listed only in the "Student Workspace (overview)" section, or not shown at all). Call ' \
                     'this BEFORE editing such a file; its contents arrive next turn in "Student Workspace (live)".',
        input_schema: {
          type: 'object',
          properties: {
            path: { type: 'string', description: 'Relative path to the file to load' }
          },
          required: %w[path]
        }
      }.freeze

      LOAD_REFERENCE_TOOL = {
        name: LOAD_REFERENCE,
        description: 'Load an instructor course material into your context. ' \
                     'Resolved by the server; the material itself is never shown to the student verbatim.',
        input_schema: {
          type: 'object',
          properties: {
            # enum doubles as a schema-level whitelist: no path hallucination.
            name: { type: 'string', enum: ['reference_solution'] }
          },
          required: %w[name]
        }
      }.freeze

      # Full toolset, in the historical order RunTutorChat sent it (behaviour-preserving).
      ALL = [EDIT_FILE, EXECUTE_SCRIPT, LOAD_FILE, LOAD_REFERENCE_TOOL].freeze

      BY_NAME = ALL.each_with_object({}) { |tool, acc| acc[tool[:name]] = tool }.freeze

      # Resolve tool names to their definitions (used to build a PersonaProfile's
      # whitelist). Unknown name → KeyError (loud, no silent drop).
      def self.named(names)
        names.map { |n| BY_NAME.fetch(n) }
      end
    end
  end
end
