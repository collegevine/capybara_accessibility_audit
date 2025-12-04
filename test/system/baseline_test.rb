require "application_system_test_case"
require "tempfile"
require "fileutils"

class BaselineTest < ApplicationSystemTestCase
  # Use a temp file for the baseline
  TEMP_IGNORE_FILE = "tmp/test_baseline.ignore.json"
  GOLDEN_FILE = "test/fixtures/baseline_ignore.json"

  def setup
    super
    # Configure baseline mode with custom output path
    self.accessibility_audit_report_mode = CapybaraAccessibilityAudit::ReportMode::BaselineCollector.new(
      output_path: TEMP_IGNORE_FILE
    )

    # Clean up from previous runs
    File.delete(TEMP_IGNORE_FILE) if File.exist?(TEMP_IGNORE_FILE)
    CapybaraAccessibilityAudit::Reporter.clear!
  end

  test "generates baseline and filters known violations" do
    # Step 1: Visit pages with violations to collect baseline
    visit violations_path(rules: ["label"])
    assert_selector "h1", text: "label"

    visit violations_path(rules: ["image-alt"])
    assert_selector "h1", text: "image-alt"

    # Step 2: Finalize to generate the baseline ignore file
    accessibility_audit_report_mode.finalize!

    assert File.exist?(TEMP_IGNORE_FILE), "Baseline ignore file should be generated"

    # If UPDATE_GOLDEN=1, save the generated file as the golden file
    if ENV["UPDATE_GOLDEN"] == "1"
      FileUtils.mkdir_p(File.dirname(GOLDEN_FILE))
      FileUtils.cp(TEMP_IGNORE_FILE, GOLDEN_FILE)
      puts "\nUpdated golden file: #{GOLDEN_FILE}"
    end

    # Verify the generated file matches the golden file
    assert File.exist?(GOLDEN_FILE), "Golden file should exist"

    generated = JSON.parse(File.read(TEMP_IGNORE_FILE))
    golden = JSON.parse(File.read(GOLDEN_FILE))

    # Remove timestamps since they change every run
    generated.delete("generated_at")
    golden.delete("generated_at")

    assert_equal golden, generated, "Generated baseline should match golden file"

    # Verify structure
    assert generated["ignored_violations"], "Should have ignored_violations key"
    assert generated["ignored_violations"]["label"], "Should have label rule"
    assert generated["ignored_violations"]["image-alt"], "Should have image-alt rule"

    # Step 3: Switch to assert mode with the generated baseline
    self.accessibility_audit_report_mode = CapybaraAccessibilityAudit::ReportMode::Assert.new(
      ignore_file_path: TEMP_IGNORE_FILE
    )

    # Step 4: Verify that known violations (in baseline) don't fail
    visit violations_path(rules: ["label"])
    assert_selector "h1", text: "label"
    # Test should pass - violation is in baseline

    visit violations_path(rules: ["image-alt"])
    assert_selector "h1", text: "image-alt"
    # Test should pass - violation is in baseline

    # Step 5: Verify that NEW violations (not in baseline) DO fail
    error = assert_raises(Minitest::Assertion) do
      visit violations_path(rules: ["button-name"])
    end

    # The page has button-name violation (not in baseline, should fail)
    # It may also have other violations like page-has-heading-one
    assert_match(/button-name|page-has-heading-one/, error.message, "Should fail on new violation not in baseline")
    assert_match(/new accessibility violations/, error.message, "Should mention new violations")
  end

  def teardown
    super
    # Clean up temp file
    File.delete(TEMP_IGNORE_FILE) if File.exist?(TEMP_IGNORE_FILE)
  end
end
