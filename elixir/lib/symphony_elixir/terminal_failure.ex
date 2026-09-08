defmodule SymphonyElixir.TerminalFailure do
  @moduledoc "Classifies unchanged launcher and workspace configuration failures."

  alias SymphonyElixir.AgentRunner

  @spec terminal?(term()) :: boolean()
  def terminal?({%AgentRunner.Error{reason: reason}, stacktrace}) when is_list(stacktrace),
    do: terminal?(reason)

  def terminal?(%AgentRunner.Error{reason: reason}), do: terminal?(reason)
  def terminal?({:port_exit, 78}), do: true
  def terminal?({:workspace_hook_failed, "after_create", 78, _output}), do: true

  # Older managed-workspace helpers returned 1 for this deterministic guard.
  # Keep the phase, status and leading diagnostic exact: other hook failures
  # (including network errors and timeouts) retain bounded retries.
  def terminal?({:workspace_hook_failed, "after_create", 1, output}) when is_binary(output) do
    String.starts_with?(output, ["logical path escapes root: ", "logical path escapes managed roots: "])
  end

  def terminal?(_reason), do: false
end
