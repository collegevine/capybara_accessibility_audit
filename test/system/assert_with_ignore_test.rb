require "application_system_test_case"

class AssertWithIgnoreTest < ApplicationSystemTestCase
  # Use the same golden file as baseline test
  GOLDEN_FILE = "test/fixtures/baseline_ignore.json"

  def setup
    super

    # Use assert mode with the golden baseline file
    # This file contains label and image-alt violations
    self.accessibility_audit_reporter = CapybaraAccessibilityAudit::Reporter::Assert.new(
      ignore_file_path: GOLDEN_FILE
    )
  end

  test "known violations from ignore file should not fail" do
    # label is in the ignore file, so test should pass
    visit violations_path(rules: ["label"])
    assert_selector "h1", text: "label"
  end

  test "new violations not in ignore file should fail" do
    # button-name is not in the ignore file, so test should fail
    error = assert_raises(Minitest::Assertion) do
      visit violations_path(rules: ["button-name"])
    end

    # May have button-name or page-has-heading-one, both are not in baseline
    assert_match(/button-name|page-has-heading-one/, error.message)
    assert_match(/new accessibility violations/, error.message)
  end

  test "page with both ignored and new violations" do
    # Visit label page first - should pass (in baseline)
    visit violations_path(rules: ["label"])
    assert_selector "h1", text: "label"

    # Visit button-name page - should fail (not in baseline)
    error = assert_raises(Minitest::Assertion) do
      visit violations_path(rules: ["button-name"])
    end

    # Should only mention new violations (button-name or page-has-heading-one), not label
    assert_match(/button-name|page-has-heading-one/, error.message)
    refute_match(/label/, error.message, "Ignored violation should not be in error message")
  end
end
