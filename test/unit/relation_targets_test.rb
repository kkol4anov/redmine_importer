# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../../lib/redmine_importer/relation_targets'

class RelationTargetsTest < Minitest::Test
  Resolver = RedmineImporter::RelationTargets
  Candidate = Struct.new(:id, :key)

  # A bounded query double keeps the selection contract testable without Rails.
  class Scope
    def initialize(items); @items = items; end
    def reorder(_order); self; end
    def limit(number); self.class.new(@items.first(number)); end
    def to_a; @items; end
  end

  def resolve(items, multiple: false, predicate: nil)
    Resolver.resolve(Scope.new(items), multiple: multiple, predicate: predicate)
  end

  def test_empty_search_is_not_a_success
    assert_raises(Resolver::Missing) { resolve([]) }
  end

  def test_unique_mode_rejects_multiple_targets_and_keeps_examples
    error = assert_raises(Resolver::Ambiguous) { resolve([1, 2, 3]) }
    assert_equal [1, 2], error.candidates
  end

  def test_all_mode_returns_every_match
    assert_equal [1, 2, 3], resolve([1, 2, 3], multiple: true)
  end

  def test_target_limit_is_inclusive
    items = (1..Resolver::MAX_TARGETS).to_a
    assert_equal items, resolve(items, multiple: true)
    assert_raises(Resolver::LimitExceeded) { resolve(items + [1001], multiple: true) }
  end

  def test_extraction_checks_exact_identifier_not_the_sql_substring
    items = [Candidate.new(1, 'K-0010'), Candidate.new(2, 'K-001')]
    assert_equal [items.last], resolve(items, predicate: ->(item) { item.key == 'K-001' })
  end

  def test_extraction_can_return_multiple_exact_matches
    items = [Candidate.new(1, 'K-001'), Candidate.new(2, 'K-001'), Candidate.new(3, 'K-0010')]
    predicate = ->(item) { item.key == 'K-001' }
    assert_equal items.first(2), resolve(items, multiple: true, predicate: predicate)
    assert_raises(Resolver::Ambiguous) { resolve(items, predicate: predicate) }
  end

  def test_no_partial_result_when_extraction_candidates_overflow
    items = (1..Resolver::MAX_CANDIDATES + 1).to_a
    assert_raises(Resolver::LimitExceeded) do
      resolve(items, multiple: true, predicate: ->(item) { item == 1 })
    end
  end

  def test_extraction_candidate_limit_is_inclusive
    items = (1..Resolver::MAX_CANDIDATES).to_a
    assert_equal [1], resolve(items, predicate: ->(item) { item == 1 })
  end

  def test_extraction_with_no_exact_match_reports_missing
    assert_raises(Resolver::Missing) { resolve([1, 2], predicate: ->(_item) { false }) }
  end
end
