require "test_helper"
require "capybara_accessibility_audit/ignore_list_merger"
require "json"
require "tempfile"

module CapybaraAccessibilityAudit
  class IgnoreListMergerTest < ActiveSupport::TestCase
    setup do
      @temp_dir = Dir.mktmpdir
    end

    teardown do
      FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    end

    test "merges two ignore lists with disjoint rules" do
      ignore1 = create_ignore_list(rules: {"label" => [create_entry(target: ["input#email"])]})
      ignore2 = create_ignore_list(rules: {"image-alt" => [create_entry(target: ["img"])]})

      merged = IgnoreListMerger.merge_data([ignore1, ignore2])

      assert_equal 2, merged[:ignored_violations].keys.count
      assert merged[:ignored_violations].key?("label")
      assert merged[:ignored_violations].key?("image-alt")
    end

    test "merges ignore lists with same rule" do
      ignore1 = create_ignore_list(rules: {
        "label" => [create_entry(html: "<input>", target: ["input#email"])]
      })
      ignore2 = create_ignore_list(rules: {
        "label" => [create_entry(html: "<input>", target: ["input#password"])]
      })

      merged = IgnoreListMerger.merge_data([ignore1, ignore2])

      assert_equal 1, merged[:ignored_violations].keys.count
      assert_equal 2, merged[:ignored_violations]["label"].count
    end

    test "deduplicates entries with same html and target" do
      entry = create_entry(html: "<input>", target: ["input#email"])
      ignore1 = create_ignore_list(rules: {"label" => [entry]})
      ignore2 = create_ignore_list(rules: {"label" => [entry]})

      merged = IgnoreListMerger.merge_data([ignore1, ignore2])

      assert_equal 1, merged[:ignored_violations]["label"].count
    end

    test "keeps entries with different html but same target" do
      entry1 = create_entry(html: "<input type='text'>", target: ["input#email"])
      entry2 = create_entry(html: "<input type='email'>", target: ["input#email"])

      ignore1 = create_ignore_list(rules: {"label" => [entry1]})
      ignore2 = create_ignore_list(rules: {"label" => [entry2]})

      merged = IgnoreListMerger.merge_data([ignore1, ignore2])

      assert_equal 2, merged[:ignored_violations]["label"].count
    end

    test "keeps entries with same html but different target" do
      entry1 = create_entry(html: "<input>", target: ["input#email"])
      entry2 = create_entry(html: "<input>", target: ["input#password"])

      ignore1 = create_ignore_list(rules: {"label" => [entry1]})
      ignore2 = create_ignore_list(rules: {"label" => [entry2]})

      merged = IgnoreListMerger.merge_data([ignore1, ignore2])

      assert_equal 2, merged[:ignored_violations]["label"].count
    end

    test "uses latest generated_at timestamp" do
      older = "2024-01-01T10:00:00Z"
      newer = "2024-01-01T11:00:00Z"

      ignore1 = create_ignore_list(generated_at: older)
      ignore2 = create_ignore_list(generated_at: newer)

      merged = IgnoreListMerger.merge_data([ignore1, ignore2])

      assert_equal newer, merged[:generated_at]
    end

    test "sorts rules alphabetically" do
      ignore1 = create_ignore_list(rules: {"zebra" => [create_entry]})
      ignore2 = create_ignore_list(rules: {"apple" => [create_entry]})
      ignore3 = create_ignore_list(rules: {"middle" => [create_entry]})

      merged = IgnoreListMerger.merge_data([ignore1, ignore2, ignore3])

      assert_equal ["apple", "middle", "zebra"], merged[:ignored_violations].keys
    end

    test "sorts entries within rules by target" do
      entry1 = create_entry(target: ["input#zebra"])
      entry2 = create_entry(target: ["input#apple"])
      entry3 = create_entry(target: ["input#middle"])

      ignore1 = create_ignore_list(rules: {"label" => [entry1, entry2, entry3]})

      merged = IgnoreListMerger.merge_data([ignore1])

      targets = merged[:ignored_violations]["label"].map { |e| e[:target] }
      assert_equal [["input#apple"], ["input#middle"], ["input#zebra"]], targets
    end

    test "returns empty ignore list for empty input" do
      merged = IgnoreListMerger.merge_data([])

      assert_equal({}, merged[:ignored_violations])
      assert merged[:generated_at].present?
      assert merged[:description].present?
    end

    test "writes merged output to file" do
      output_path = File.join(@temp_dir, "merged.ignore.json")
      ignore1 = create_ignore_list(rules: {"label" => [create_entry]})
      ignore2 = create_ignore_list(rules: {"image-alt" => [create_entry]})

      ignore_file1 = write_ignore_list(ignore1, "ignore1.json")
      ignore_file2 = write_ignore_list(ignore2, "ignore2.json")

      IgnoreListMerger.merge(
        ignore_paths: [ignore_file1, ignore_file2],
        output_path: output_path
      )

      assert File.exist?(output_path)
      merged = JSON.parse(File.read(output_path), symbolize_names: true)
      assert_equal 2, merged[:ignored_violations].keys.count
    end

    test "raises error when no paths provided" do
      assert_raises(ArgumentError, match: /No ignore list paths provided/) do
        IgnoreListMerger.new(ignore_paths: [], output_path: "output.json").merge
      end
    end

    test "raises error when file doesn't exist" do
      assert_raises(ArgumentError, match: /File not found/) do
        IgnoreListMerger.new(
          ignore_paths: ["nonexistent.json"],
          output_path: "output.json"
        ).merge
      end
    end

    test "raises error on invalid JSON" do
      invalid_file = File.join(@temp_dir, "invalid.json")
      File.write(invalid_file, "not valid json")

      assert_raises(JSON::ParserError) do
        IgnoreListMerger.new(
          ignore_paths: [invalid_file],
          output_path: "output.json"
        ).merge
      end
    end

    private

    def create_ignore_list(rules: {}, generated_at: Time.now.iso8601)
      {
        generated_at: generated_at,
        description: "Test ignore list",
        ignored_violations: rules
      }
    end

    def create_entry(html: "<div>Test</div>", target: ["div#test"])
      {html: html, target: target}
    end

    def write_ignore_list(ignore_data, filename)
      path = File.join(@temp_dir, filename)
      File.write(path, JSON.generate(ignore_data))
      path
    end
  end
end
