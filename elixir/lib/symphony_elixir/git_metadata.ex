defmodule SymphonyElixir.GitMetadata do
  @moduledoc false

  alias SymphonyElixir.PathSafety

  @spec writable_roots(Path.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def writable_roots(workspace, workspace_root)
      when is_binary(workspace) and is_binary(workspace_root) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(Path.expand(workspace_root)),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(Path.expand(workspace)),
         :ok <- require_strict_descendant(canonical_workspace, canonical_root, :workspace),
         {:ok, git_metadata} <- resolve_git_metadata(canonical_workspace, canonical_root) do
      {:ok, [canonical_workspace, git_metadata]}
    end
  end

  def writable_roots(workspace, workspace_root) do
    {:error, {:unsafe_git_metadata, {:invalid_paths, workspace, workspace_root}}}
  end

  defp resolve_git_metadata(workspace, workspace_root) do
    dot_git = Path.join(workspace, ".git")

    case File.lstat(dot_git) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, dot_git}

      {:ok, %File.Stat{type: :regular}} ->
        resolve_linked_git_metadata(dot_git, workspace, workspace_root)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_git_metadata, {:unsupported_dot_git_type, type}}}

      {:error, reason} ->
        {:error, {:unsafe_git_metadata, {:dot_git_unreadable, reason}}}
    end
  end

  defp resolve_linked_git_metadata(dot_git, workspace, workspace_root) do
    expected_broker_git =
      workspace_root
      |> Path.join(".broker/git")
      |> Path.join(Path.basename(workspace))

    with {:ok, content} <- File.read(dot_git),
         [path] <- Regex.run(~r/^gitdir:\s*(\S(?:.*\S)?)\s*$/u, content, capture: :all_but_first),
         expanded <- Path.expand(path, workspace),
         {:ok, canonical_git} <- PathSafety.canonicalize(expanded),
         :ok <- require_strict_descendant(canonical_git, workspace_root, :linked_gitdir),
         {:ok, canonical_expected_git} <- PathSafety.canonicalize(expected_broker_git),
         :ok <- require_expected_broker_git(canonical_git, canonical_expected_git),
         {:ok, %File.Stat{type: :directory}} <- File.stat(canonical_git) do
      {:ok, canonical_git}
    else
      nil ->
        {:error, {:unsafe_git_metadata, :invalid_gitdir_pointer}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_git_metadata, {:linked_gitdir_not_directory, type}}}

      {:error, {:unsafe_git_metadata, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:unsafe_git_metadata, reason}}
    end
  end

  defp require_expected_broker_git(path, path), do: :ok

  defp require_expected_broker_git(path, expected) do
    {:error, {:unsafe_git_metadata, {:unexpected_linked_gitdir, path, expected}}}
  end

  defp require_strict_descendant(path, root, kind) do
    if String.starts_with?(path <> "/", root <> "/") and path != root do
      :ok
    else
      {:error, {:unsafe_git_metadata, {kind, :outside_workspace_root, path, root}}}
    end
  end
end
