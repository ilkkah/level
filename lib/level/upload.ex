defmodule Level.Upload do
  @moduledoc """
  The Upload schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Level.Posts.Post
  alias Level.PostUpload
  alias Level.Spaces.Space
  alias Level.Spaces.SpaceUser

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "uploads" do
    field :filename, :string
    field :content_type, :string
    field :size, :integer

    belongs_to :space, Space
    belongs_to :space_user, SpaceUser
    has_many :post_uploads, PostUpload
    has_many :posts, through: [:post_uploads, :post]

    timestamps()
  end

  @doc false
  def create_changeset(struct, attrs \\ %{}) do
    struct
    |> cast(attrs, [:space_id, :space_user_id, :filename, :content_type, :size])
  end
end
