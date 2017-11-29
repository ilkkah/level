defmodule Level.Connections.RoomSubscriptions do
  @moduledoc false

  alias Level.Rooms.RoomSubscription
  import Ecto.Query

  @default_args %{
    first: 10,
    before: nil,
    after: nil,
    order_by: %{
      field: :inserted_at,
      direction: :desc
    }
  }

  @doc """
  Execute a paginated query for room subscriptions belonging to a given user.
  """
  def get(user, args, _context) do
    case validate_args(args) do
      {:ok, args} ->
        base_query = from s in RoomSubscription, where: s.user_id == ^user.id
        Level.Pagination.fetch_result(Level.Repo, base_query, args)
      error ->
        error
    end
  end

  defp validate_args(args) do
    # TODO: return {:error, message} if args are not valid
    {:ok, Map.merge(@default_args, args)}
  end
end
