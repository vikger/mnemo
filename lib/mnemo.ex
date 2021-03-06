defmodule Mnemo do
  @moduledoc """
  Implementation of [BIP39](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
  """

  @valid_strenghts [128, 160, 192, 224, 256]
  @default_strength 256
  @valid_mnemonic_word_count [12, 15, 18, 21, 24]
  @pbkdf2_opts rounds: 2048, digest: :sha512, length: 64, format: :hex

  @doc """
  Generates random English mnemonic.
  Optional entropy length (`strength`) argument can be provided; defaults to 256 bits.
  """
  def generate(strength \\ @default_strength) when strength in @valid_strenghts do
    strength
    |> div(8)
    |> :crypto.strong_rand_bytes()
    |> mnemonic()
  end

  @doc """
  Generates English mnemonic for pre-existing entropy (obtained from elsehwere).
  """
  def mnemonic(entropy) do
    entropy
    |> maybe_decode()
    |> update_with_checksum()
    |> sentence()
    |> Enum.map(&word/1)
    |> Enum.join(" ")
  end

  @doc """
  Converts English mnemonic to its binary entropy.
  Validates the provided number of words, their existence in English wordlist
  and finally, the checksum.

  If `hex: true` option is provided, the result is hex-encoded.
  """
  def entropy(mnemonic, opts \\ []) do
    words = String.split(mnemonic)

    if length(words) not in @valid_mnemonic_word_count do
      raise "Number of words must be one of the following: [12, 15, 18, 21, 24]"
    end

    sentence = for(word <- words, do: <<index(word)::size(11)>>, into: "")
    divider_index = floor(bit_size(sentence) / 33) * 32
    <<entropy::size(divider_index), checksum::bitstring>> = sentence

    ent = <<entropy::size(divider_index)>>
    cs = decode_integer(checksum)

    as_hex? = Keyword.get(opts, :hex, false)

    case checksum(ent) do
      {^cs, _} ->
        if as_hex?, do: Base.encode16(ent, case: :lower), else: ent

      {other, _} ->
        raise "Invalid mnemonic (checksum mismatch): #{inspect(mnemonic)}. Got #{other}, expected: #{
                cs
              }"
    end
  end

  @doc """
  Retrieves English word by index.
  Non-English wordlists are not implemented yet.
  """
  def word(i, lang \\ :english) when i in 0..2047 do
    lang
    |> wordlist_stream()
    |> Stream.filter(fn {_value, index} -> index == i end)
    |> Enum.at(0)
    |> elem(0)
    |> String.trim()
  end

  @doc """
  Retrieves index for an English word.
  Non-English wordlists are not implemented yet.
  """
  def index(word, lang \\ :english) when is_binary(word) do
    fetch = fn
      [] -> raise "Invalid word: #{word}"
      [{_word, index}] -> index
    end

    lang
    |> wordlist_stream()
    |> Stream.filter(fn {value, _index} -> String.trim(value) == word end)
    |> Stream.take(1)
    |> Enum.to_list()
    |> fetch.()
  end

  @doc """
  Derives a hex-encoded PBKDF2 seed from mnemonic.
  Optional passhprase can be provided in the second argument.

  Does not validate any mnemonic properties.
  """
  def seed(mnemonic, passphrase \\ "") do
    Pbkdf2.Base.hash_password(mnemonic, "mnemonic#{passphrase}", @pbkdf2_opts)
  end

  @doc """
  Returns a list of 11-bit word indices for given ENT_CS.
  """
  def sentence(ent_cs), do: bit_chunk(ent_cs, 11)

  @doc """
  Decodes unsigned integer from a binary. Bitstrings are left-padded.
  """
  def decode_integer(b) when is_bitstring(b) do
    b
    |> pad_leading_zeros()
    |> :binary.decode_unsigned(:big)
  end

  @doc """
  Calculates CS for given ENT.
  Returns a tuple consisting of the checksum and its bit size.
  """
  def checksum(ent) do
    s = div(bit_size(ent), 32)
    {bit_slice(:crypto.hash(:sha256, ent), s), s}
  end

  @doc """
  Left pads a bitstring with zeros.
  """
  def pad_leading_zeros(bs) when is_binary(bs), do: bs

  def pad_leading_zeros(bs) when is_bitstring(bs) do
    pad_length = 8 - rem(bit_size(bs), 8)
    <<0::size(pad_length), bs::bitstring>>
  end

  @doc """
  Splits bitstring `b` into `n`-bit chunks.
  """
  def bit_chunk(b, n) when is_bitstring(b) and is_integer(n) and n > 1 do
    bit_chunk(b, n, [])
  end

  defp bit_chunk(b, n, acc) when bit_size(b) <= n do
    Enum.reverse([decode_integer(<<b::bitstring>>) | acc])
  end

  defp bit_chunk(b, n, acc) do
    <<chunk::size(n), rest::bitstring>> = b
    bit_chunk(rest, n, [decode_integer(<<chunk::size(n)>>) | acc])
  end

  defp bit_slice(bin, n) do
    <<x::integer-size(n), _t::bitstring>> = bin
    x
  end

  defp maybe_decode(ent) do
    ent =
      case Base.decode16(ent, case: :mixed) do
        :error -> ent
        {:ok, decoded} -> decoded
      end

    bit_size(ent) in @valid_strenghts || raise "ENT must be #{inspect(@valid_strenghts)} bits"
    ent
  end

  defp update_with_checksum(ent) do
    {checksum, checksum_size} = checksum(ent)
    <<ent::binary, checksum::size(checksum_size)>>
  end

  defp wordlist_stream(lang) do
    :mnemo
    |> Application.app_dir()
    |> Path.join("priv/#{lang}.txt")
    |> File.stream!()
    |> Stream.with_index()
  end
end
