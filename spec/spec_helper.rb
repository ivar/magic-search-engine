require_relative "../lib/card_database"
require_relative "../lib/cli_frontend"
require "pry"

RSpec.configure do |config|
  config.expect_with(:rspec) do |c|
    c.syntax = :should
  end
  config.define_derived_metadata do |meta|
    meta[:aggregate_failures] = true
  end
end

RSpec::Matchers.define :include_cards do |*cards|
  match do |query_string|
    results = search(query_string)
    cards.all?{|card| results.include?(card)}
  end

  failure_message do |query_string|
    results = search(query_string)
    fails = cards.reject{|card| results.include?(card)}
    "Expected `#{query_string}' to include following cards:\n" +
      fails.map{|c| "* #{c}\n"}.join
  end
end

RSpec::Matchers.define :exclude_cards do |*cards|
  match do |query_string|
    results = search(query_string)
    results != [] and cards.none?{|card| results.include?(card)}
  end

  failure_message do |query_string|
    results = search(query_string)
    fails = cards.select{|card| results.include?(card)}
    if fails != []
      "Expected `#{query_string}' to exclude following cards:\n" +
        fails.map{|c| "* #{c}\n"}.join
    else
      "Test is unreliable because results are empty: #{query_string}"
    end
  end
end

RSpec::Matchers.define :return_no_cards do
  match do |query_string|
    search(query_string) == []
  end

  failure_message do |query_string|
    results = search(query_string)
    "Expected `#{query_string}' to have no results, but got following cards:\n" +
      results.map{|c| "* #{c}\n"}.join
  end
end

RSpec::Matchers.define :return_cards do |*cards|
  match do |query_string|
    search(query_string).sort == cards.sort
  end

  failure_message do |query_string|
    results = search(query_string)
    "Expected `#{query_string}' to return:\n" +
      (cards | results).sort.map{|c|
        (cards.include?(c) ? "[*]" : "[ ]") +
        (results.include?(c) ? "[*]" : "[ ]") +
        "#{c}\n"
      }.join
  end
end

RSpec::Matchers.define :return_cards_in_order do |*cards|
  match do |query_string|
    search(query_string) == cards
  end

  # TODO: Better error message here
  failure_message do |query_string|
    results = search(query_string)
    "Expected `#{query_string}' to return:\n" +
      cards.map{|c| "* #{c}\n"}.join +
    "\nInstead got:" +
      results.map{|c| "* #{c}\n"}.join
  end
end

RSpec::Matchers.define :equal_search do |query_string2|
  match do |query_string1|
    results1 = search(query_string1)
    results2 = search(query_string2)
    results1 == results2 and results1 != []
  end

  failure_message do |query_string1|
    results1 = search(query_string1)
    results2 = search(query_string2)
    if results1 != results2
      "Expected `#{query_string1}' and `#{query_string2}' to return same results, got:\n"+
        (results1 | results2).sort.map{|c|
        (results1.include?(c) ? "[*]" : "[ ]") +
        (results2.include?(c) ? "[*]" : "[ ]") +
        "#{c}\n"
      }.join
    else
      "Test is unreliable because results are empty: #{query_string1}"
    end
  end
end

RSpec::Matchers.define :have_result_count do |count|
  match do |query_string|
    search(query_string).size == count
  end

  failure_message do |query_string|
    "Expected `#{query_string}' to return #{count} results, got #{search(query_string).size} instead."
  end
end

shared_context "db" do |*sets|
  def load_database(*sets)
    $card_database ||= {}
    $card_database[[]]   ||= CardDatabase.load(Pathname(__dir__) + "../data/index.json")
    $card_database[sets] ||= $card_database[[]].subset(sets)
  end

  def search(query_string)
    Query.new(query_string).search(db).card_names
  end

  let!(:db) { load_database(*sets) }

  # FIXME: Temporary hacks to make migration to rspec easier, remove after migration complete
  def assert_search_results(query, *cards)
    query.should return_cards(*cards)
  end
  def assert_search_include(query, *cards)
    query.should include_cards(*cards)
  end
  def assert_search_exclude(query, *cards)
    query.should exclude_cards(*cards)
  end
  def assert_search_equal(query1, query2)
    query1.should equal_search(query2)
  end
  def assert_search_differ(query1, query2)
    query1.should_not equal_search(query2)
  end
  def assert_count_results(query, count)
    query.should have_result_count(count)
  end
  def assert_search_results_ordered(query, *results)
    query.should return_cards_in_order(*results)
  end
  def assert_full_banlist(format, time, banned_cards, restricted_cards=[])
    time = Date.parse(time)
    expected_banlist = Hash[
      banned_cards.map{|c| [c, "banned"]} +
      restricted_cards.map{|c| [c, "restricted"]}
    ]
    actual_banlist = ban_list.full_ban_list(format, time)
    expected_banlist.should eq(actual_banlist)
  end
  def assert_banlist_changes(date, *changes)
    prev_date = Date.parse(date)
    this_date = (prev_date >> 1) + 5
    changes.each_slice(2) do |change, card|
      raise unless change =~ /\A(.*) (\S+)\z/
      assert_banlist_change prev_date, this_date, $1, $2, card
    end
  end
  def assert_banlist_change(prev_date, this_date, format, change, card)
    if format == "vintage+"
      change_legacy = change
      case change
      when "banned", "restricted"
        change_legacy = "banned"
      when "unbanned", "unrestricted"
        change_legacy = "unbanned"
      when "banned-to-restricted", "restricted-to-banned"
        change_legacy = nil
      else
        raise
      end
      assert_banlist_change(prev_date, this_date, "vintage", change, card)
      assert_banlist_change(prev_date, this_date, "legacy", change_legacy, card) if change_legacy
      return
    end
    case change
    when "banned"
      assert_banlist_status(prev_date, format, "legal", card)
      assert_banlist_status(this_date, format, "banned", card)
    when "unbanned"
      assert_banlist_status(prev_date, format, "banned", card)
      assert_banlist_status(this_date, format, "legal", card)
    when "restricted"
      assert_banlist_status(prev_date, format, "legal", card)
      assert_banlist_status(this_date, format, "restricted", card)
    when "unrestricted"
      assert_banlist_status(prev_date, format, "restricted", card)
      assert_banlist_status(this_date, format, "legal", card)
    when "banned-to-restricted"
      assert_banlist_status(prev_date, format, "banned", card)
      assert_banlist_status(this_date, format, "restricted", card)
    when "restricted-to-banned"
      assert_banlist_status(prev_date, format, "restricted", card)
      assert_banlist_status(this_date, format, "banned", card)
    else
      raise
    end
  end
  def assert_banlist_status(date, format, expected_legality, card_name)
    if date.is_a?(Date)
      dsc = "#{date}"
      set_date = date
    else
      dsc = "#{set} (#{set_date})"
      set_date = db.sets[set].release_date
    end
    actual_legality = ban_list.legality(format, card_name, set_date) || "legal"
    expected_legality.should eq(actual_legality)
  end
end
