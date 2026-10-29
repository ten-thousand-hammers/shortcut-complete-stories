# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

class CompleteStoriesTest < Minitest::Test
  SCRIPT = File.expand_path("../complete-stories.sh", __dir__)

  def setup
    @directory = Dir.mktmpdir
    FileUtils.mkdir_p("#{@directory}/bin")
    # The previous release is found from deploy run titles, passing over runs whose job
    # log (job N for run N) started this action without finishing it. PR 10 names its
    # story in the branch, PR 11 in the title.
    stub_command("gh", <<~'BASH')
      args="$*"; echo "gh ${args//$'\n'/ }" >> "$CALL_LOG"
      case "$*" in *"${FAIL_GH:-none}"*) echo "HTTP 503: Service Unavailable" >&2; exit 1 ;; esac
      if [ -n "${OLD_GH:-}" ] && [ "$1 $2" = "api --allow-escape-sequences" ]; then
        echo 'unknown flag: --allow-escape-sequences' >&2; exit 1
      fi
      case "$*" in
        "run list"*) printf '%s\t%s\n' 3 "Deploy: 2026.10.26+1" 2 "Release 2026.10.25+3" 1 "Deploy: 2026.10.24+1" ;;
        *runs/*/jobs*) run="${args##*runs/}"; echo "${run%%/*}" ;;
        *jobs/*/logs*)
          job="${args##*jobs/}"; job="${job%%/*}"
          case " ${UNFINISHED_JOBS:-} " in
            *" $job "*) printf '2026-10-26T10:00:00Z shortcut-complete-stories: started\n' ;;
            *) printf '2026-10-26T10:00:00Z shortcut-complete-stories: started\n2026-10-26T10:00:01Z shortcut-complete-stories: finished\n' ;;
          esac ;;
        *compare/*) printf 'aaa\nbbb\n' ;;
        *commits/aaa/pulls*) printf '10\tnathanpalmer/sc-11/first\tfeat: first\n' ;;
        *commits/bbb/pulls*) printf '11\tfix/other\tfix: other [sc-12]\n' ;;
      esac
    BASH
    stub_command("curl", <<~'BASH')
      method=GET; url=""; data=""; previous=""
      for arg; do
        case "$arg" in https://*) url="$arg" ;; esac
        [ "$previous" = "-X" ] && method="$arg"
        [ "$previous" = "-d" ] && data="$arg"
        previous="$arg"
      done
      id="${url##*/}"
      case "$method $url" in
        "PUT "*/stories/*)
          echo "PUT $id $data" >> "$CALL_LOG"
          [ "$id" = "${FAIL_PUT:-}" ] && exit 22
          echo '{}' ;;
        "GET "*/stories/*)
          [ "$id" = "${DONE_ID:-}" ] && completed=true || completed=false
          echo "{\"completed\":$completed,\"workflow_id\":7}" ;;
        "GET "*/workflows/*)
          echo '{"states":[{"id":1,"name":"Started"},{"id":8,"name":"Released"},{"id":9,"name":"Completed"}]}' ;;
      esac
    BASH
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_completes_stories_named_in_branches_and_titles_since_the_last_deploy
    output, status = run_script

    assert status.success?, output
    assert_includes gh_call("run list"), "--workflow deploy.yml"
    assert_includes gh_call("compare/"), "--paginate repos/ten-thousand-hammers/plan-your-work/compare/2026.10.26+1...2026.10.27+1"
    assert_includes gh_call("commits/aaa/pulls"), '.base.ref == "main"'
    assert_equal ['PUT 11 {"workflow_state_id":9}', 'PUT 12 {"workflow_state_id":9}'], updates
    assert_includes summary, "Pull requests deployed since 2026.10.26+1: #10 #11"
    assert_includes summary, "[sc-12](https://app.shortcut.com/apsure/story/12): Completed in 2026.10.27+1"
  end

  def test_skips_the_release_being_deployed_when_finding_the_last_deploy
    output, status = run_script({}, "2026.10.26+1")

    assert status.success?, output
    assert_includes gh_call("compare/"), "compare/2026.10.25+3...2026.10.26+1"
  end

  def test_retries_the_stories_of_deploys_that_did_not_finish_completing_them
    output, status = run_script("UNFINISHED_JOBS" => "3 2")

    assert status.success?, output
    assert_includes gh_call("compare/"), "compare/2026.10.24+1...2026.10.27+1"
    assert_includes summary, "Retrying the stories of deploys that didn't complete them: 2026.10.26+1 2026.10.25+3"
  end

  def test_a_deploy_without_the_log_lines_counts_as_completed
    stub_command("gh", <<~'BASH')
      args="$*"; echo "gh ${args//$'\n'/ }" >> "$CALL_LOG"
      case "$*" in
        "run list"*) printf '%s\t%s\n' 3 "Deploy: 2026.10.26+1" ;;
        *runs/*/jobs*) echo 3 ;;
        *jobs/*/logs*) echo "HTTP 410: Gone" >&2; exit 1 ;;
      esac
    BASH

    output, status = run_script

    assert status.success?, output
    assert_includes gh_call("compare/"), "compare/2026.10.26+1...2026.10.27+1"
  end

  def test_when_no_deploy_completed_its_stories_starts_from_the_oldest
    output, status = run_script("UNFINISHED_JOBS" => "3 2 1")

    assert status.success?, output
    assert_includes gh_call("compare/"), "compare/2026.10.24+1...2026.10.27+1"
    assert_includes output, "those of 2026.10.24+1 and earlier must be completed by hand"
    assert_includes summary, "didn't complete them: 2026.10.26+1 2026.10.25+3\n"
  end

  def test_a_github_error_reading_a_deploy_fails_without_finishing
    output, status = run_script("FAIL_GH" => "logs")

    refute status.success?
    assert_includes output, "Could not read the deploy run for 2026.10.26+1"
    refute_includes output, "shortcut-complete-stories: finished"
    assert_empty updates
  end

  def test_a_repository_without_the_deploy_workflow_has_no_earlier_deploy
    stub_command("gh", <<~'BASH')
      echo "HTTP 404: workflow deploy.yml not found on the default branch" >&2; exit 1
    BASH

    output, status = run_script

    assert status.success?, output
    assert_includes output, "No earlier successful deploy"
    assert_includes output, "shortcut-complete-stories: finished"
  end

  def test_a_github_error_listing_deploys_fails_without_finishing
    output, status = run_script("FAIL_GH" => "run list")

    refute status.success?
    assert_includes output, "HTTP 503"
    refute_includes output, "shortcut-complete-stories: finished"
  end

  def test_reads_every_page_of_a_runs_jobs
    run_script

    assert_includes gh_call("runs/3/jobs"), "--paginate"
  end

  def test_reads_logs_with_a_gh_that_has_no_escape_sequence_flag
    output, status = run_script("OLD_GH" => "1", "UNFINISHED_JOBS" => "3")

    assert status.success?, output
    assert_includes gh_call("compare/"), "compare/2026.10.25+3...2026.10.27+1"
  end

  def test_logs_finished_only_when_it_succeeds
    output, status = run_script
    assert status.success?, output
    assert_match(/started\n.*finished\n\z/m, output)

    output, status = run_script("FAIL_PUT" => "11")
    refute status.success?
    assert_includes output, "shortcut-complete-stories: started"
    refute_includes output, "shortcut-complete-stories: finished"
  end

  def test_inputs_choose_the_workflow_branch_state_and_workspace
    output, status = run_script(
      "WORKFLOW" => "release.yml", "BASE_BRANCH" => "production",
      "END_STATE" => "Released", "SHORTCUT_WORKSPACE" => "acme"
    )

    assert status.success?, output
    assert_includes gh_call("run list"), "--workflow release.yml"
    assert_includes gh_call("commits/aaa/pulls"), '.base.ref == "production"'
    assert_equal ['PUT 11 {"workflow_state_id":8}', 'PUT 12 {"workflow_state_id":8}'], updates
    assert_includes summary, "[sc-12](https://app.shortcut.com/acme/story/12): Released in 2026.10.27+1"
  end

  def test_a_failed_update_still_completes_the_other_stories_and_fails_the_step
    output, status = run_script("FAIL_PUT" => "11")

    refute status.success?
    assert_includes output, "sc-11 could not be moved to Completed"
    assert_equal ["PUT 11", "PUT 12"], updates.map { |call| call.split.first(2).join(" ") }
    assert_includes summary, "sc-11: could not be moved to Completed"
    assert_includes summary, "[sc-12]"
  end

  def test_skips_stories_that_are_already_done
    output, status = run_script("DONE_ID" => "11")

    assert status.success?, output
    assert_equal ["PUT 12"], updates.map { |call| call.split.first(2).join(" ") }
    assert_includes summary, "sc-11: already done"
  end

  def test_dry_run_lists_the_stories_without_shortcut
    output, status = run_script("DRY_RUN" => "1", "SHORTCUT_TOKEN" => "")

    assert status.success?, output
    assert_includes summary, "Would complete: sc-11 sc-12"
    assert_empty updates
  end

  def test_fails_without_a_token_unless_dry_run
    output, status = run_script("SHORTCUT_TOKEN" => "")

    refute status.success?
    assert_includes output, "Set shortcut-token"
    assert_empty calls
  end

  private

  def stub_command(name, body)
    path = "#{@directory}/bin/#{name}"
    File.write(path, "#!/usr/bin/env bash\n#{body}")
    FileUtils.chmod("+x", path)
  end

  def run_script(environment = {}, tag = "2026.10.27+1")
    Open3.capture2e({
      "PATH" => "#{@directory}/bin:#{ENV.fetch("PATH")}",
      "CALL_LOG" => "#{@directory}/calls.log",
      "GITHUB_STEP_SUMMARY" => "#{@directory}/summary.md",
      "GITHUB_REPOSITORY" => "ten-thousand-hammers/plan-your-work",
      "SHORTCUT_TOKEN" => "test-token"
    }.merge(environment), SCRIPT, tag)
  end

  def calls
    File.exist?("#{@directory}/calls.log") ? File.readlines("#{@directory}/calls.log", chomp: true) : []
  end

  def gh_call(fragment)
    calls.find { |call| call.start_with?("gh ") && call.include?(fragment) } || flunk("No gh call with #{fragment}")
  end

  def updates
    calls.grep(/\APUT /)
  end

  def summary
    File.read("#{@directory}/summary.md")
  end
end
