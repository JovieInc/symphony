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

      not present_string?(tracker_settings.project_slug) and
          not present_string?(tracker_settings.team_key) ->
        {:error, :missing_linear_scope}

      present_string?(tracker_settings.project_slug) and
          present_string?(tracker_settings.team_key) ->
        {:error, :ambiguous_linear_scope}

      present_string?(tracker_settings.team_key) and
          not valid_team_key?(tracker_settings.team_key) ->
        {:error, :invalid_linear_team_key}

      not is_nil(tracker_settings.assignee) and not present_string?(tracker_settings.assignee) ->
        {:error, :invalid_linear_assignee}

      true ->
        :ok
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

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  # Linear team keys are short uppercase identifiers (for example "ENG", "JOV").
  # Anything else fails closed so a malformed team scope can never widen or
  # silently empty the intake scope.
  defp valid_team_key?(value) when is_binary(value) do
    String.match?(String.trim(value), ~r/^[A-Z][A-Z0-9]*$/)
  end
end
