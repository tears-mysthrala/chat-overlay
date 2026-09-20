# Build-time inventory only; inputs are the verified lockfile and Hex metadata.
[output] = System.argv()
File.mkdir_p!(output)

components =
  Enum.map(Mix.Dep.Lock.read(), fn {name, {:hex, _, version, _, _, _, "hexpm", checksum}} ->
    {:ok, metadata} = :file.consult(String.to_charlist("deps/#{name}/hex_metadata.config"))
    licenses = :proplists.get_value("licenses", metadata)

    unless is_list(licenses) and licenses != [] and
             Enum.all?(licenses, &(&1 in ["MIT", "Apache-2.0"])),
           do: raise("Missing or unreviewed dependency license")

    directory = Path.join(output, "licenses/#{name}")
    File.mkdir_p!(directory)

    files =
      Path.wildcard("deps/#{name}/*")
      |> Enum.filter(
        &String.starts_with?(String.upcase(Path.basename(&1)), ["LICENSE", "NOTICE", "COPYING"])
      )

    files =
      if name == :mint_web_socket,
        do: ["vendor/licenses/mint_web_socket-LICENSE" | files],
        else: files

    if files == [], do: raise("Missing license text for #{name}")
    Enum.each(files, &File.cp!(&1, Path.join(directory, Path.basename(&1))))

    %{
      "type" => "library",
      "name" => to_string(name),
      "version" => version,
      "bom-ref" => "pkg:hex/#{name}@#{version}",
      "purl" => "pkg:hex/#{name}@#{version}",
      "hashes" => [%{"alg" => "SHA-256", "content" => checksum}],
      "licenses" => Enum.map(licenses, &%{"license" => %{"id" => &1}})
    }
  end)

dependencies =
  Enum.map(Mix.Dep.Lock.read(), fn {name, {:hex, _, version, _, _, deps, _, _}} ->
    refs =
      for {dep, _, opts} <- deps,
          not opts[:optional] or Map.has_key?(Mix.Dep.Lock.read(), dep),
          do: "pkg:hex/#{dep}@#{elem(Map.fetch!(Mix.Dep.Lock.read(), dep), 2)}"

    %{"ref" => "pkg:hex/#{name}@#{version}", "dependsOn" => refs}
  end)

File.write!(
  Path.join(output, "hex-components.json"),
  JSON.encode!(%{"components" => components, "dependencies" => dependencies})
)

IO.puts("Reviewed #{length(components)} dependency licenses; texts and checksums included")
