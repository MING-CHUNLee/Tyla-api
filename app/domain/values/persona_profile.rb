# frozen_string_literal: true

module Tyla
  module Values
    # The per-persona capability bundle (MS3 plan §7.1): the round-1 tool whitelist
    # plus two prompt-injection booleans that decide whether the builder renders the
    # workspace/line-number guides (inject_workspace) and the reference-solution
    # manifest (inject_reference).
    #
    # Phase 1 only carries this inside a PersonaResolution; the mini-loop (tools) and
    # prompt builder (inject_*) start consuming it in Phases 2–3.
    PersonaProfile = Data.define(:tools, :inject_workspace, :inject_reference) do
      # The whitelist of tool names, used to gate BOTH action channels (§7.3): the
      # native tool_use branch and the prose `<actions>` fallback. tier3 → [].
      def tool_names
        tools.map { |tool| tool[:name] }
      end
    end
  end
end
