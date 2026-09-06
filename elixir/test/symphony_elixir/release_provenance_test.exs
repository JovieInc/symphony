defmodule SymphonyElixir.ReleaseProvenanceTest do
  use ExUnit.Case, async: true

  @repository "JovieInc/symphony"
  @source_sha String.duplicate("a", 40)
  @run_id 12_345
  @run_attempt 2
  @targets ~w(linux_x86_64 linux_arm64 macos_x86_64 macos_arm64)
  @script Path.expand("../../../.github/scripts/release_provenance.py", __DIR__)
  @workflow Path.expand("../../../.github/workflows/burrito-release.yml", __DIR__)

  test "accepts only a successful exact make-all main push" do
    fixture = ci_fixture()
    assert {"", 0} = run_verify_ci(fixture)
  end

  test "rejects failed, stale, foreign, and mismatched CI receipts" do
    invalid_receipts = [
      {"failed run", fn fixture -> put_in(fixture, [:run, "conclusion"], "failure") end},
      {"stale source", fn fixture -> put_in(fixture, [:main_ref, "object", "sha"], String.duplicate("b", 40)) end},
      {"foreign repository", fn fixture -> put_in(fixture, [:run, "repository", "full_name"], "elsewhere/symphony") end},
      {"wrong event", fn fixture -> put_in(fixture, [:run, "event"], "pull_request") end},
      {"wrong attempt", fn fixture -> put_in(fixture, [:run, "run_attempt"], @run_attempt + 1) end},
      {"wrong workflow", fn fixture -> put_in(fixture, [:run, "workflow_id"], 999) end}
    ]

    for {label, mutate} <- invalid_receipts do
      {_output, status} = ci_fixture() |> mutate.() |> run_verify_ci()
      assert status == 1, "expected #{label} to be rejected"
    end
  end

  test "assembles a deterministic release that verifies repeatedly and detects mutation" do
    root = tmp_dir("release")
    input = Path.join(root, "input")
    output = Path.join(root, "output")

    for target <- @targets do
      artifact = "symphony-#{@source_sha}-#{target}"
      build_dir = Path.join(input, "build-#{target}")
      smoke_dir = Path.join(input, "smoke-#{target}")
      File.mkdir_p!(build_dir)
      File.mkdir_p!(smoke_dir)
      artifact_path = Path.join(build_dir, artifact)
      File.write!(artifact_path, "binary for #{target}\n")
      digest = sha256(artifact_path)
      File.write!(Path.join(build_dir, "#{artifact}.sha256"), "#{digest}  #{artifact}\n")

      write_json(Path.join(build_dir, "#{artifact}.provenance.json"), %{
        repository: @repository,
        source_sha: @source_sha,
        target: target,
        artifact: artifact,
        sha256: digest,
        make_all: %{
          workflow_path: ".github/workflows/make-all.yml",
          run_id: @run_id,
          run_attempt: @run_attempt,
          event: "push",
          conclusion: "success"
        }
      })

      write_json(Path.join(smoke_dir, "#{artifact}.smoke.json"), %{
        repository: @repository,
        source_sha: @source_sha,
        target: target,
        artifact: artifact,
        sha256: digest,
        make_all_run_id: @run_id,
        make_all_run_attempt: @run_attempt,
        result: "passed",
        observed_exit_status: 1
      })
    end

    assert {"", 0} = run_script(["assemble" | release_args()] ++ ["--input-dir", input, "--output-dir", output])
    assert {"", 0} = run_script(["verify-release" | release_args()] ++ ["--release-dir", output])
    assert {"", 0} = run_script(["verify-release" | release_args()] ++ ["--release-dir", output])

    File.write!(Path.join(output, "symphony-#{@source_sha}-linux_x86_64"), "mutated")
    {_output, status} = run_script(["verify-release" | release_args()] ++ ["--release-dir", output])
    assert status == 1
  end

  test "workflow requires bounded dispatch inputs, smoke receipts, and no asset replacement" do
    workflow = File.read!(@workflow)
    assert workflow =~ "source_sha:"
    assert workflow =~ "make_all_run_id:"
    assert workflow =~ "make_all_run_attempt:"
    assert workflow =~ "github.ref == 'refs/heads/main'"
    assert workflow =~ "needs: [provenance, build, smoke]"
    assert workflow =~ "ref: ${{ inputs.source_sha }}"
    refute workflow =~ "--clobber"
    refute workflow =~ "push:\n    tags:"
  end

  defp ci_fixture do
    %{
      main_ref: %{"object" => %{"type" => "commit", "sha" => @source_sha}},
      workflow: %{
        "id" => 42,
        "path" => ".github/workflows/make-all.yml",
        "name" => "make-all",
        "state" => "active"
      },
      run: %{
        "id" => @run_id,
        "run_attempt" => @run_attempt,
        "workflow_id" => 42,
        "repository" => %{"full_name" => @repository},
        "head_repository" => %{"full_name" => @repository},
        "head_sha" => @source_sha,
        "head_branch" => "main",
        "event" => "push",
        "status" => "completed",
        "conclusion" => "success",
        "html_url" => "https://github.com/JovieInc/symphony/actions/runs/#{@run_id}"
      }
    }
  end

  defp run_verify_ci(fixture) do
    root = tmp_dir("ci")
    main_ref = Path.join(root, "main-ref.json")
    workflow = Path.join(root, "workflow.json")
    run = Path.join(root, "run.json")
    output = Path.join(root, "verified.json")
    write_json(main_ref, fixture.main_ref)
    write_json(workflow, fixture.workflow)
    write_json(run, fixture.run)

    run_script([
      "verify-ci",
      "--repository",
      @repository,
      "--source-sha",
      @source_sha,
      "--run-id",
      Integer.to_string(@run_id),
      "--run-attempt",
      Integer.to_string(@run_attempt),
      "--main-ref-json",
      main_ref,
      "--workflow-json",
      workflow,
      "--run-json",
      run,
      "--output",
      output
    ])
  end

  defp release_args do
    [
      "--repository",
      @repository,
      "--source-sha",
      @source_sha,
      "--run-id",
      Integer.to_string(@run_id),
      "--run-attempt",
      Integer.to_string(@run_attempt)
    ]
  end

  defp run_script(args) do
    System.cmd("python3", [@script | args], stderr_to_stdout: true)
  end

  defp write_json(path, value) do
    File.write!(path, Jason.encode!(value))
  end

  defp sha256(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp tmp_dir(label) do
    path = Path.join(System.tmp_dir!(), "symphony-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
