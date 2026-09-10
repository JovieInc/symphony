defmodule SymphonyElixir.TemporaryAdmission do
  @moduledoc """
  Strict machine receipts for temporary inventory and dispatch admission refusals.
  These receipts authorize waiting, never dispatch or provider capacity.
  """

  @inventory ~r/\ASYMPHONY_LAUNCHER_FAILURE schema=symphony-launcher-failure\/v1 class=pr-inventory-unknown retryable=true reason="open_pr_inventory_unknown (?<identifier>[A-Z][A-Z0-9]*-[1-9][0-9]*)"\z/
  @admission ~r/\ASYMPHONY_LAUNCHER_FAILURE schema=symphony-launcher-failure\/v1 class=pickup-refused retryable=true reason="(?<reason>dispatch_gate_closed|dispatch_admission_unavailable) owns (?<identifier>[A-Z][A-Z0-9]*-[1-9][0-9]*)"\z/

  @spec parse_line(String.t()) :: {:ok, map()} | :error
  def parse_line(line) do
    case Regex.named_captures(@inventory, line) do
      %{"identifier" => identifier} -> receipt(:pr_inventory_unknown, "open_pr_inventory_unknown", identifier)
      nil -> parse_admission(line)
    end
  end

  @spec from_hook(term()) :: {:ok, map()} | :error
  def from_hook({:workspace_hook_failed, "before_run", 75, output}) when is_binary(output) do
    case output |> String.split("\n", trim: true) |> Enum.filter(&String.contains?(&1, ["SYMPHONY_LAUNCHER_FAILURE", "CAPACITY_UNAVAILABLE"])) do
      [line] -> parse_line(line)
      _ -> :error
    end
  end

  def from_hook(_reason), do: :error

  defp parse_admission(line) do
    case Regex.named_captures(@admission, line) do
      %{"identifier" => identifier, "reason" => reason} -> receipt(:dispatch_admission, reason, identifier)
      nil -> :error
    end
  end

  defp receipt(class, reason, identifier) do
    {:ok,
     %{
       schema: "symphony-launcher-failure/v1",
       class: class,
       retryable: true,
       reason: reason,
       identifier: identifier,
       retry_at: nil,
       wait_seconds: nil
     }}
  end
end
