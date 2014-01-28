##
## Inspired by mochiweb's reloader (Copyright 2007 Mochi Media, Inc.)
##
defmodule ExReloader do
  use Application.Behaviour
  alias GenX.Supervisor, as: Sup

  def start do
    :ok = Application.start :exreloader
  end

  def start(_, _) do
    Sup.start_link sup_tree
  end

  defp sup_tree do
    interval = Application.environment(:exreloader)[:interval] || 1000
    Sup.OneForOne.new(id: ExReloader.Server.Sup,
                      registered: :exreloader_sup,
                      children: [Sup.Worker.new(id: ExReloader.Server,
                                                start_func: {ExReloader.Server, :start_link, [interval]})])
  end

  ##

  def reload_modules(modules) do
    lc module inlist modules, do: reload(module)
  end

  def reload(module) do
    :error_logger.info_msg "Reloading module: #{inspect module}"
    :code.purge(module)
    :code.load_file(module)
  end

  def reload_file(file_name) do
    :error_logger.info_msg "Reloading from sources: #{file_name}"
    try do
      Code.load_file(file_name)
    rescue
      x in [CompileError] ->
        :error_logger.error_msg "Compile Error: #{inspect x.message}"
    end
  end

  def all_changed() do
    lc {m, f} inlist :code.all_loaded, is_list(f), changed?(m), do: m
  end

  def changed?(module) do
    try do
        module_vsn(module.module_info) != module_vsn(:code.get_object_code(module))
    catch _ ->
        false
    end
  end

  defp module_vsn({m, beam, _f}) do
    {:ok, {^m, vsn}} = :beam_lib.version(beam)
    vsn
  end
  defp module_vsn(l) when is_list(l) do
    {_, attrs} = :lists.keyfind(:attributes, 1, l)
    {_, vsn} = :lists.keyfind(:vsn, 1, attrs)
    vsn
  end

end

defmodule ExReloader.Server do
  use GenServer.Behaviour
  import GenX.GenServer
  alias :gen_server, as: GenServer

  def start_link(interval // 1000) do
    GenServer.start {:local, :exreloader_checker}, __MODULE__, interval, []
  end

  def init(interval) do
    {:ok, {timestamp, interval}, interval}
  end

  defcall stop, state: state do
    {:stop, :shutdown, :stopped, state}
  end

  definfo timeout, state: {last, timeout} do
    now = timestamp
    run(last, now)
    {:noreply, {now, timeout}, timeout}
  end

  defp timestamp, do: :erlang.localtime

  defp run(from, to) do
    appmod_pattern = %r/^Elixir\.#{Mix.project[:app]}/i
    lc {module, filename} inlist :code.all_loaded,
        (module |> to_string =~ appmod_pattern),
        is_list(filename) do
      case File.stat(filename) do
        {:ok, File.Stat[mtime: mtime]} when mtime >= from and mtime < to ->
          :error_logger.info_msg "File #{inspect filename} modified. Reloading..."
          {:ok, file_name} = String.from_char_list(filename)
          cond do
            String.ends_with? file_name, ".ex" ->
              ExReloader.reload_file(file_name)
            String.ends_with? file_name, ".beam" ->
              ExReloader.reload(module)
            true ->
              :ok
          end
        {:ok, _} -> :unmodified
        {:error, :enoent} -> :gone
        other -> other
      end
    end
  end

end
