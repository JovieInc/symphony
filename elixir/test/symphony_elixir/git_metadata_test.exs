defmodule SymphonyElixir.GitMetadataTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitMetadata

  test "regular clone roots permit git metadata writes and a real fetch" do
    root = temp_root("regular")
    remote = Path.join(root, "remote.git")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "ISSUE-1")
    sibling = Path.join(workspace_root, "ISSUE-2")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(sibling)
    on_exit(fn -> File.rm_rf(root) end)

    assert {_output, 0} = System.cmd("git", ["init", "--bare", remote], stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("git", ["clone", remote, workspace], stderr_to_stdout: true)

    assert {:ok, [canonical_workspace, canonical_git]} =
             GitMetadata.writable_roots(workspace, workspace_root)

    assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
    assert canonical_workspace == expected_workspace
    assert canonical_git == Path.join(canonical_workspace, ".git")
    refute sibling in [canonical_workspace, canonical_git]

    assert {_output, 0} =
             System.cmd("git", ["fetch", "origin"], cd: workspace, stderr_to_stdout: true)

    assert File.exists?(Path.join(canonical_git, "FETCH_HEAD"))
  end

  test "linked gitdir is allowed only inside the configured workspace root" do
    root = temp_root("linked")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "ISSUE-1")
    broker_git = Path.join(workspace_root, ".broker/git/ISSUE-1")
    outside_git = Path.join(root, "outside.git")
    File.mkdir_p!(workspace)
    File.mkdir_p!(broker_git)
    File.mkdir_p!(outside_git)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join(workspace, ".git"), "gitdir: #{broker_git}\n")
    assert {:ok, canonical_broker_git} = SymphonyElixir.PathSafety.canonicalize(broker_git)

    assert {:ok, [_, ^canonical_broker_git]} =
             GitMetadata.writable_roots(workspace, workspace_root)

    sibling_git = Path.join(workspace_root, "ISSUE-2/.git")
    File.mkdir_p!(sibling_git)
    File.write!(Path.join(workspace, ".git"), "gitdir: ../ISSUE-2/.git\n")
    assert {:ok, canonical_sibling_git} = SymphonyElixir.PathSafety.canonicalize(sibling_git)

    assert {:error, {:unsafe_git_metadata, sibling_reason}} =
             GitMetadata.writable_roots(workspace, workspace_root)

    assert sibling_reason ==
             {:unexpected_linked_gitdir, canonical_sibling_git, canonical_broker_git}

    File.write!(Path.join(workspace, ".git"), "gitdir: ../../outside.git\n")

    assert {:ok, canonical_outside_git} = SymphonyElixir.PathSafety.canonicalize(outside_git)

    assert {:error, {:unsafe_git_metadata, outside_reason}} =
             GitMetadata.writable_roots(workspace, workspace_root)

    assert {:linked_gitdir, :outside_workspace_root, ^canonical_outside_git, _canonical_root} =
             outside_reason

    File.write!(Path.join(workspace, ".git"), "gitdir: #{broker_git}\n")
    File.rm_rf!(broker_git)
    File.write!(broker_git, "not a directory")

    assert {:error, {:unsafe_git_metadata, {:linked_gitdir_not_directory, :regular}}} =
             GitMetadata.writable_roots(workspace, workspace_root)

    invalid_segment = String.duplicate("a", 300)
    File.write!(Path.join(workspace, ".git"), "gitdir: ../#{invalid_segment}\n")

    assert {:error, {:unsafe_git_metadata, {:path_canonicalize_failed, _, :enametoolong}}} =
             GitMetadata.writable_roots(workspace, workspace_root)
  end

  test "workspace and dot-git symlink escapes fail closed" do
    root = temp_root("symlink")
    workspace_root = Path.join(root, "workspaces")
    outside_workspace = Path.join(root, "outside/ISSUE-1")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(Path.join(outside_workspace, ".git"))
    on_exit(fn -> File.rm_rf(root) end)

    linked_workspace = Path.join(workspace_root, "ISSUE-1")
    File.ln_s!(outside_workspace, linked_workspace)

    assert {:error, {:unsafe_git_metadata, {:workspace, :outside_workspace_root, _outside, _canonical_root}}} =
             GitMetadata.writable_roots(linked_workspace, workspace_root)

    File.rm!(linked_workspace)
    File.mkdir_p!(linked_workspace)
    File.ln_s!(Path.join(outside_workspace, ".git"), Path.join(linked_workspace, ".git"))

    assert {:error, {:unsafe_git_metadata, {:unsupported_dot_git_type, :symlink}}} =
             GitMetadata.writable_roots(linked_workspace, workspace_root)
  end

  test "runtime policy preserves explicit fields and replaces roots with exact source roots" do
    root = temp_root("policy")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "ISSUE-1")
    File.mkdir_p!(Path.join(workspace, ".git"))
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: ["/unsafe/sibling"],
        networkAccess: false,
        readOnlyAccess: %{type: "fullAccess"},
        custom: %{keep: true}
      }
    )

    assert {:ok, settings} = Config.codex_runtime_settings(workspace)
    assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
    assert settings.thread_sandbox == "workspace-write"

    assert settings.turn_sandbox_policy["writableRoots"] == [
             canonical_workspace,
             Path.join(canonical_workspace, ".git")
           ]

    assert settings.turn_sandbox_policy["networkAccess"] == true
    assert settings.turn_sandbox_policy["custom"] == %{"keep" => true}
    refute "/unsafe/sibling" in settings.turn_sandbox_policy["writableRoots"]
  end

  test "missing and malformed git metadata fail closed" do
    root = temp_root("invalid")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "ISSUE-1")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:unsafe_git_metadata, {:dot_git_unreadable, :enoent}}} =
             GitMetadata.writable_roots(workspace, workspace_root)

    File.write!(Path.join(workspace, ".git"), "not a gitdir pointer\n")

    assert {:error, {:unsafe_git_metadata, :invalid_gitdir_pointer}} =
             GitMetadata.writable_roots(workspace, workspace_root)

    assert {:error, {:unsafe_git_metadata, {:invalid_paths, 123, ^workspace_root}}} =
             GitMetadata.writable_roots(123, workspace_root)
  end

  defp temp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "symphony-git-metadata-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
