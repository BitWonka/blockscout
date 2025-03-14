defmodule BlockScoutWeb.AddressTransactionControllerTest do
  use BlockScoutWeb.ConnCase, async: true
  use ExUnit.Case, async: false

  import BlockScoutWeb.Routers.WebRouter.Helpers, only: [address_transaction_path: 3, address_transaction_path: 4]
  import Mox

  alias Explorer.Chain.{Address, Transaction}
  alias Explorer.ExchangeRates.Token

  setup :verify_on_exit!

  describe "GET index/2" do
    setup :set_mox_global

    test "with invalid address hash", %{conn: conn} do
      conn = get(conn, address_transaction_path(conn, :index, "invalid_address"))

      assert html_response(conn, 422)
    end

    if Application.compile_env(:explorer, :chain_type) !== :rsk do
      test "with valid address hash without address in the DB", %{conn: conn} do
        conn =
          get(
            conn,
            address_transaction_path(conn, :index, Address.checksum("0x8bf38d4764929064f2d4d3a56520a76ab3df415b"), %{
              "type" => "JSON"
            })
          )

        assert json_response(conn, 200)
        transaction_tiles = json_response(conn, 200)["items"]
        assert transaction_tiles |> length() == 0
      end
    end

    test "returns transactions for the address", %{conn: conn} do
      address = insert(:address)

      block = insert(:block)

      from_transaction =
        :transaction
        |> insert(from_address: address)
        |> with_block(block)

      to_transaction =
        :transaction
        |> insert(to_address: address)
        |> with_block(block)

      conn = get(conn, address_transaction_path(conn, :index, Address.checksum(address), %{"type" => "JSON"}))

      transaction_tiles = json_response(conn, 200)["items"]
      transaction_hashes = Enum.map([to_transaction.hash, from_transaction.hash], &to_string(&1))

      assert Enum.all?(transaction_hashes, fn transaction_hash ->
               Enum.any?(transaction_tiles, &String.contains?(&1, transaction_hash))
             end)
    end

    test "includes USD exchange rate value for address in assigns", %{conn: conn} do
      address = insert(:address)

      conn = get(conn, address_transaction_path(BlockScoutWeb.Endpoint, :index, Address.checksum(address.hash)))

      assert %Token{} = conn.assigns.exchange_rate
    end

    test "returns next page of results based on last seen transaction", %{conn: conn} do
      address = insert(:address)

      second_page_hashes =
        50
        |> insert_list(:transaction, from_address: address)
        |> with_block()
        |> Enum.map(& &1.hash)

      %Transaction{block_number: block_number, index: index} =
        :transaction
        |> insert(from_address: address)
        |> with_block()

      conn =
        get(conn, address_transaction_path(BlockScoutWeb.Endpoint, :index, Address.checksum(address.hash)), %{
          "block_number" => Integer.to_string(block_number),
          "index" => Integer.to_string(index),
          "type" => "JSON"
        })

      transaction_tiles = json_response(conn, 200)["items"]

      assert Enum.all?(second_page_hashes, fn address_hash ->
               Enum.any?(transaction_tiles, &String.contains?(&1, to_string(address_hash)))
             end)
    end

    test "next_page_params exist if not on last page", %{conn: conn} do
      address = insert(:address)
      block = insert(:block)

      60
      |> insert_list(:transaction, from_address: address)
      |> with_block(block)

      conn = get(conn, address_transaction_path(conn, :index, Address.checksum(address.hash), %{"type" => "JSON"}))

      assert json_response(conn, 200)["next_page_path"]
    end

    test "next_page_params are empty if on last page", %{conn: conn} do
      address = insert(:address)

      :transaction
      |> insert(from_address: address)
      |> with_block()

      conn = get(conn, address_transaction_path(conn, :index, Address.checksum(address.hash), %{"type" => "JSON"}))

      refute json_response(conn, 200)["next_page_path"]
    end

    test "returns parent transaction for a contract address", %{conn: conn} do
      address = insert(:address, contract_code: data(:address_contract_code))
      block = insert(:block)

      transaction =
        :transaction
        |> insert(to_address: nil, created_contract_address_hash: address.hash)
        |> with_block(block)
        |> Explorer.Repo.preload([[created_contract_address: :names], [from_address: :names], :token_transfers])

      insert(
        :internal_transaction_create,
        index: 0,
        created_contract_address: address,
        to_address: nil,
        transaction: transaction,
        block_hash: block.hash,
        block_index: 0
      )

      conn = get(conn, address_transaction_path(conn, :index, Address.checksum(address)), %{"type" => "JSON"})

      transaction_tiles = json_response(conn, 200)["items"]

      assert Enum.all?([transaction.hash], fn transaction_hash ->
               Enum.any?(transaction_tiles, &String.contains?(&1, to_string(transaction_hash)))
             end)
    end
  end

  describe "GET token-transfers-csv/2" do
    setup do
      csv_setup()
    end

    test "do not export token transfers to csv without recaptcha recaptcha_response provided", %{conn: conn} do
      address = insert(:address)

      transaction =
        :transaction
        |> insert(from_address: address)
        |> with_block()

      insert(:token_transfer, transaction: transaction, from_address: address, block_number: transaction.block_number)
      insert(:token_transfer, transaction: transaction, to_address: address, block_number: transaction.block_number)

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/token-transfers-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period
        })

      assert conn.status == 403
    end

    test "do not export token transfers to csv without recaptcha passed", %{
      conn: conn,
      v2_secret_key: recaptcha_secret_key
    } do
      expected_body = "secret=#{recaptcha_secret_key}&response=123"

      Explorer.Mox.HTTPoison
      |> expect(:post, fn _url, ^expected_body, _headers, _options ->
        {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(%{"success" => false})}}
      end)

      address = insert(:address)

      transaction =
        :transaction
        |> insert(from_address: address)
        |> with_block()

      insert(:token_transfer, transaction: transaction, from_address: address, block_number: transaction.block_number)
      insert(:token_transfer, transaction: transaction, to_address: address, block_number: transaction.block_number)

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/token-transfers-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period,
          "recaptcha_response" => "123"
        })

      assert conn.status == 403
    end

    test "exports token transfers to csv without recaptcha if recaptcha is disabled", %{conn: conn} do
      init_config = Application.get_env(:block_scout_web, :recaptcha)
      Application.put_env(:block_scout_web, :recaptcha, is_disabled: true)

      address = insert(:address)

      transaction =
        :transaction
        |> insert(from_address: address)
        |> with_block()

      insert(:token_transfer, transaction: transaction, from_address: address, block_number: transaction.block_number)
      insert(:token_transfer, transaction: transaction, to_address: address, block_number: transaction.block_number)

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/token-transfers-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period
        })

      assert conn.resp_body |> String.split("\n") |> Enum.count() == 4

      Application.put_env(:block_scout_web, :recaptcha, init_config)
    end

    test "exports token transfers to csv", %{conn: conn, v2_secret_key: recaptcha_secret_key} do
      expected_body = "secret=#{recaptcha_secret_key}&response=123"

      Explorer.Mox.HTTPoison
      |> expect(:post, fn _url, ^expected_body, _headers, _options ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           body:
             Jason.encode!(%{
               "success" => true,
               "hostname" => Application.get_env(:block_scout_web, BlockScoutWeb.Endpoint)[:url][:host]
             })
         }}
      end)

      address = insert(:address)

      transaction =
        :transaction
        |> insert(from_address: address)
        |> with_block()

      insert(:token_transfer, transaction: transaction, from_address: address, block_number: transaction.block_number)
      insert(:token_transfer, transaction: transaction, to_address: address, block_number: transaction.block_number)

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/token-transfers-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period,
          "recaptcha_response" => "123"
        })

      assert conn.resp_body |> String.split("\n") |> Enum.count() == 4
    end
  end

  describe "GET transactions_csv/2" do
    setup do
      csv_setup()
    end

    test "download csv file with transactions", %{conn: conn, v2_secret_key: recaptcha_secret_key} do
      expected_body = "secret=#{recaptcha_secret_key}&response=123"

      Explorer.Mox.HTTPoison
      |> expect(:post, fn _url, ^expected_body, _headers, _options ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           body:
             Jason.encode!(%{
               "success" => true,
               "hostname" => Application.get_env(:block_scout_web, BlockScoutWeb.Endpoint)[:url][:host]
             })
         }}
      end)

      address = insert(:address)

      :transaction
      |> insert(from_address: address)
      |> with_block()

      :transaction
      |> insert(from_address: address)
      |> with_block()

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/transactions-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period,
          "recaptcha_response" => "123"
        })

      assert conn.resp_body |> String.split("\n") |> Enum.count() == 4
    end
  end

  describe "GET internal_transactions_csv/2" do
    setup do
      csv_setup()
    end

    test "download csv file with internal transactions", %{conn: conn, v2_secret_key: recaptcha_secret_key} do
      expected_body = "secret=#{recaptcha_secret_key}&response=123"

      Explorer.Mox.HTTPoison
      |> expect(:post, fn _url, ^expected_body, _headers, _options ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           body:
             Jason.encode!(%{
               "success" => true,
               "hostname" => Application.get_env(:block_scout_web, BlockScoutWeb.Endpoint)[:url][:host]
             })
         }}
      end)

      address = insert(:address)

      transaction_1 =
        :transaction
        |> insert()
        |> with_block()

      transaction_2 =
        :transaction
        |> insert()
        |> with_block()

      transaction_3 =
        :transaction
        |> insert()
        |> with_block()

      insert(:internal_transaction,
        index: 3,
        transaction: transaction_1,
        from_address: address,
        block_number: transaction_1.block_number,
        block_hash: transaction_1.block_hash,
        block_index: 0,
        transaction_index: transaction_1.index
      )

      insert(:internal_transaction,
        index: 1,
        transaction: transaction_2,
        to_address: address,
        block_number: transaction_2.block_number,
        block_hash: transaction_2.block_hash,
        block_index: 1,
        transaction_index: transaction_2.index
      )

      insert(:internal_transaction,
        index: 2,
        transaction: transaction_3,
        created_contract_address: address,
        block_number: transaction_3.block_number,
        block_hash: transaction_3.block_hash,
        block_index: 2,
        transaction_index: transaction_3.index
      )

      from_period = Timex.format!(Timex.shift(Timex.now(), years: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/internal-transactions-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period,
          "recaptcha_response" => "123"
        })

      assert conn.resp_body |> String.split("\n") |> Enum.count() == 5
    end
  end

  describe "GET logs_csv/2" do
    setup do
      csv_setup()
    end

    test "download csv file with logs", %{conn: conn, v2_secret_key: recaptcha_secret_key} do
      expected_body = "secret=#{recaptcha_secret_key}&response=123"

      Explorer.Mox.HTTPoison
      |> expect(:post, fn _url, ^expected_body, _headers, _options ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           body:
             Jason.encode!(%{
               "success" => true,
               "hostname" => Application.get_env(:block_scout_web, BlockScoutWeb.Endpoint)[:url][:host]
             })
         }}
      end)

      address = insert(:address)

      transaction_1 =
        :transaction
        |> insert()
        |> with_block()

      insert(:log,
        address: address,
        index: 3,
        transaction: transaction_1,
        block: transaction_1.block,
        block_number: transaction_1.block_number
      )

      transaction_2 =
        :transaction
        |> insert()
        |> with_block()

      insert(:log,
        address: address,
        index: 1,
        transaction: transaction_2,
        block: transaction_2.block,
        block_number: transaction_2.block_number
      )

      transaction_3 =
        :transaction
        |> insert()
        |> with_block()

      insert(:log,
        address: address,
        index: 2,
        transaction: transaction_3,
        block: transaction_3.block,
        block_number: transaction_3.block_number
      )

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/logs-csv", %{
          "address_id" => Address.checksum(address.hash),
          "from_period" => from_period,
          "to_period" => to_period,
          "recaptcha_response" => "123"
        })

      assert conn.resp_body |> String.split("\n") |> Enum.count() == 5
    end

    test "handles null filter", %{conn: conn, v2_secret_key: recaptcha_secret_key} do
      expected_body = "secret=#{recaptcha_secret_key}&response=123"

      Explorer.Mox.HTTPoison
      |> expect(:post, fn _url, ^expected_body, _headers, _options ->
        {:ok,
         %HTTPoison.Response{
           status_code: 200,
           body:
             Jason.encode!(%{
               "success" => true,
               "hostname" => Application.get_env(:block_scout_web, BlockScoutWeb.Endpoint)[:url][:host]
             })
         }}
      end)

      address = insert(:address)

      transaction =
        :transaction
        |> insert()
        |> with_block()

      insert(:log,
        address: address,
        index: 3,
        transaction: transaction,
        block: transaction.block,
        block_number: transaction.block_number
      )

      from_period = Timex.format!(Timex.shift(Timex.now(), minutes: -1), "%Y-%m-%d", :strftime)
      to_period = Timex.format!(Timex.now(), "%Y-%m-%d", :strftime)

      conn =
        get(conn, "/api/v1/logs-csv", %{
          "address_id" => Address.checksum(address.hash),
          "filter_type" => "null",
          "filter_value" => "null",
          "from_period" => from_period,
          "to_period" => to_period,
          "recaptcha_response" => "123"
        })

      assert conn.resp_body |> String.split("\n") |> Enum.count() == 3
    end
  end

  defp csv_setup() do
    old_recaptcha_env = Application.get_env(:block_scout_web, :recaptcha)
    old_http_adapter = Application.get_env(:block_scout_web, :http_adapter)

    v2_secret_key = "v2_secret_key"
    v3_secret_key = "v3_secret_key"

    Application.put_env(:block_scout_web, :recaptcha,
      v2_secret_key: v2_secret_key,
      v3_secret_key: v3_secret_key,
      is_disabled: false
    )

    Application.put_env(:block_scout_web, :http_adapter, Explorer.Mox.HTTPoison)

    on_exit(fn ->
      Application.put_env(:block_scout_web, :recaptcha, old_recaptcha_env)
      Application.put_env(:block_scout_web, :http_adapter, old_http_adapter)
    end)

    {:ok, %{v2_secret_key: v2_secret_key, v3_secret_key: v3_secret_key}}
  end
end
