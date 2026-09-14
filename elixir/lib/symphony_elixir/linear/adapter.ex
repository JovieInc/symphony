defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    cond do
      not present_string?(tracker_settings.endpoint) ->
        {:error, :invalid_linear_endpoint}

      not present_string?(tracker_settings.api_key) ->
        {:error, :missing_linear_api_token}

      match?({:error, _}, scope_for(tracker_settings)) ->
        {:error, :missing_linear_project_slug}

      not is_nil(tracker_settings.assignee) and not present_string?(tracker_settings.assignee) ->
        {:error, :invalid_linear_assignee}

      true ->
        :ok
    end
  end

  @doc """
  Returns the configured Linear read scope.

  Project-scoped workflows keep their existing behavior. A workflow may instead
  provide `tracker.provider.team_key`, which lets the runtime query the whole
  team without inventing a project boundary. The caller still owns any label,
  state, admission, and execution restrictions layered on top of this scope.
  """
  @spec scope_for(map()) :: {:ok, {:project | :team, String.t()}} | {:error, atom()}
  def scope_for(tracker_settings) do
    cond do
      present_string?(tracker_settings.project_slug) ->
        {:ok, {:project, tracker_settings.project_slug}}

      present_string?(provider_value(tracker_settings, "team_key")) ->
        {:ok, {:team, provider_value(tracker_settings, "team_key")}}

      true ->
        {:error, :missing_linear_project_slug}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) do
    AgentTool.execute(tool, arguments, opts)
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: tracker_settings.secret_environment_names

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp provider_value(%{provider: provider}, "team_key") when is_map(provider) do
    Map.get(provider, "team_key")
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
