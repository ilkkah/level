defmodule Level.Repo.Migrations.CreateReplies do
  use Ecto.Migration

  def change do
    create table(:replies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, on_delete: :nothing, type: :binary_id), null: false

      add :space_user_id, references(:space_users, on_delete: :nothing, type: :binary_id),
        null: false

      add :post_id, references(:posts, on_delete: :nothing, type: :binary_id), null: false

      add :body, :text, null: false

      timestamps()
    end
  end
end
