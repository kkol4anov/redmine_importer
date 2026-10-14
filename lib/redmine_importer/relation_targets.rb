# frozen_string_literal: true

module RedmineImporter
  # Resolves a bounded, visible, pre-filtered scope without writing links.
  # The controller supplies the same identifier/extraction rules as the import.
  class RelationTargets
    MAX_TARGETS = 1000
    MAX_CANDIDATES = 10_000
    class Missing < StandardError; end
    class LimitExceeded < StandardError; end
    class Ambiguous < StandardError
      attr_reader :candidates
      def initialize(candidates)
        @candidates = candidates
        super('Multiple relation targets')
      end
    end

    def self.resolve(scope, multiple:, predicate: nil)
      limit = predicate ? MAX_CANDIDATES : (multiple ? MAX_TARGETS : 1)
      candidates = scope.reorder('issues.id ASC').limit(limit + 1).to_a
      # Never silently use a truncated candidate set, even if its first few
      # entries appear to identify just one extracted value.
      raise LimitExceeded if predicate && candidates.size > MAX_CANDIDATES
      candidates = candidates.select(&predicate) if predicate
      raise Missing if candidates.empty?
      raise Ambiguous.new(candidates.first(2)) if !multiple && candidates.size > 1
      raise LimitExceeded if candidates.size > MAX_TARGETS
      candidates
    end
  end
end
