defmodule Exduckdb.ConnectionTest do
  use ExUnit.Case

  alias Exduckdb.Connection
  alias Exduckdb.Query
  alias Exduckdb.DuckDB

  describe ".connect/1" do
    test "returns error when path is missing from options" do
      {:error, error} = Connection.connect([])

      assert error.message ==
               ~s{You must provide a :database to the database. Example: connect(database: "./") or connect(database: :memory)}
    end

    test "connects to an in memory database" do
      {:ok, state} = Connection.connect(database: ":memory:")

      assert state.path == ":memory:"
      assert state.db
    end

    test "connects to in memory when the memory atom is passed" do
      {:ok, state} = Connection.connect(database: :memory)

      assert state.path == ":memory:"
      assert state.db
    end

    test "connects to a file" do
      path = Temp.path!()
      {:ok, state} = Connection.connect(database: path)

      assert state.path == path
      assert state.db

      File.rm(path)
    end
  end

  describe ".disconnect/2" do
    test "disconnects a database that was never connected" do
      conn = %Connection{db: nil, path: nil}

      assert :ok == Connection.disconnect(nil, conn)
    end

    test "disconnects a connected database" do
      {:ok, conn} = Connection.connect(database: :memory)

      assert :ok == Connection.disconnect(nil, conn)
    end
  end

  describe ".handle_execute/4" do
    test "returns records" do
      path = Temp.path!()

      {:ok, db} = DuckDB.open(path)

      :ok = DuckDB.execute(db, "create table users (id integer primary key, name text)")

      :ok = DuckDB.execute(db, "insert into users (id, name) values (1, 'Jim')")
      :ok = DuckDB.execute(db, "insert into users (id, name) values (2, 'Bob')")
      :ok = DuckDB.execute(db, "insert into users (id, name) values (3, 'Dave')")
      :ok = DuckDB.execute(db, "insert into users (id, name) values (4, 'Steve')")
      DuckDB.close(db)

      {:ok, conn} = Connection.connect(database: path)

      {:ok, _query, result, _conn} =
        %Query{statement: "select * from users where id < ?"}
        |> Connection.handle_execute([4], [], conn)

      assert result.command == :execute
      assert result.columns == ["id", "name"]
      assert result.rows == [[1, "Jim"], [2, "Bob"], [3, "Dave"]]

      File.rm(path)
    end

    test "returns correctly for empty result" do
      path = Temp.path!()

      {:ok, db} = DuckDB.open(path)

      :ok = DuckDB.execute(db, "create table users (id integer primary key, name text)")

      DuckDB.close(db)

      {:ok, conn} = Connection.connect(database: path)

      {:ok, _query, result, _conn} =
        %Query{
          statement: "UPDATE users set name = 'wow' where id = 1",
          command: :update
        }
        |> Connection.handle_execute([], [], conn)

      assert result.rows == nil

      {:ok, _query, result, _conn} =
        %Query{
          statement: "UPDATE users set name = 'wow' where id = 5",
          command: :update
        }
        |> Connection.handle_execute([], [], conn)

      assert result.rows == nil

      File.rm(path)
    end

    test "returns timely and in order for big data sets" do
      path = Temp.path!()

      {:ok, db} = DuckDB.open(path)

      :ok = DuckDB.execute(db, "create table users (id integer primary key, name text)")

      1..10_000
      |> Stream.chunk_every(20)
      |> Stream.each(fn chunk ->
        values = Enum.map_join(chunk, ", ", fn i -> "(#{i}, 'User-#{i}')" end)
        DuckDB.execute(db, "insert into users (id, name) values #{values}")
      end)
      |> Stream.run()

      :ok = DuckDB.close(db)

      {:ok, conn} = Connection.connect(database: path)

      {:ok, _query, result, _conn} =
        Connection.handle_execute(
          %Query{
            statement: "SELECT * FROM users"
          },
          [],
          [timeout: 1],
          conn
        )

      assert result.command == :execute
      assert length(result.rows) == 10_000

      Enum.with_index(result.rows, fn row, i ->
        assert row == [i + 1, "User-#{i + 1}"]
      end)

      File.rm(path)
    end
  end

  describe ".handle_prepare/3" do
    test "returns a prepared query" do
      {:ok, conn} = Connection.connect(database: :memory)

      {:ok, _query, _result, conn} =
        %Query{statement: "create table users (id integer primary key, name text)"}
        |> Connection.handle_execute([], [], conn)

      {:ok, query, conn} =
        %Query{statement: "select * from users where id < ?"}
        |> Connection.handle_prepare([], conn)

      assert conn
      assert query
      assert query.ref
      assert query.statement
    end

    test "users table does not exist" do
      {:ok, conn} = Connection.connect(database: :memory)

      {:error, error, _state} =
        %Query{statement: "select * from users where id < ?"}
        |> Connection.handle_prepare([], conn)

      assert error.message == "no such table: users"
    end
  end

  describe ".checkout/1" do
    test "checking out an idle connection" do
      {:ok, conn} = Connection.connect(database: :memory)

      {:ok, conn} = Connection.checkout(conn)
      assert conn.status == :busy
    end

    test "checking out a busy connection" do
      {:ok, conn} = Connection.connect(database: :memory)
      conn = %{conn | status: :busy}

      {:disconnect, error, _conn} = Connection.checkout(conn)

      assert error.message == "Database is busy"
    end
  end

  describe ".ping/1" do
    test "returns the state passed unchanged" do
      {:ok, conn} = Connection.connect(database: :memory)

      assert {:ok, conn} == Connection.ping(conn)
    end
  end

  describe ".handle_close/3" do
    test "releases the underlying prepared statement" do
      {:ok, conn} = Connection.connect(database: :memory)

      {:ok, query, _result, conn} =
        %Query{statement: "create table users (id integer primary key, name text)"}
        |> Connection.handle_execute([], [], conn)

      assert {:ok, nil, conn} == Connection.handle_close(query, [], conn)

      {:ok, query, conn} =
        %Query{statement: "select * from users where id < ?"}
        |> Connection.handle_prepare([], conn)

      assert {:ok, nil, conn} == Connection.handle_close(query, [], conn)
    end
  end
end
