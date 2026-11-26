# Native HTTP lifecycle fixture. Run in an isolated RGSS process with the
# .tools/run-http-toggle.py host; never load this in a user's running game.
class Scene_Base
  def update_basic; end
end

module HttpToggleRGSS
  def self.check(value, message)
    raise message unless value
  end

  def self.wait_for
    deadline = Time.now + 15
    until yield
      raise 'host handshake timed out' if Time.now > deadline
      Graphics.update
    end
  end

  def self.checkpoint(name, poll = false)
    File.open('checkpoint', 'wb') { |file| file.write(name) }
    wait_for do
      ModLoader::Http.tick if poll
      File.exist?('continue') && File.read('continue') == name
    end
  end

  def self.run
    begin
      base = File.join(ModLoader.data_directory, 'framework')
      ['core/resetter.rb', 'core/nvram.rb', 'input/settings.rb', 'http/router.rb'].each do |component|
        path = File.join(base, component)
        eval(File.read(path), TOPLEVEL_BINDING, path)
      end
      settings = ModLoader::InputSettings
      http = ModLoader::Http
      http.get('/ping') { { 'ok' => true } }
      phase = File.read('phase')
      if phase == 'fresh'
        port, next_port, busy_port = File.read('ports').split.map { |v| v.to_i }
        http.tick
        check(!settings.http_enabled? && !http.running?, 'HTTP must default to OFF')
        checkpoint('default-off')

        check(settings.save_http_port(busy_port.to_s), 'save busy port')
        check(!settings.save_http_enabled(true), 'occupied port must reject enable')
        check(!http.running? && !settings.http_enabled?, 'failed enable must stay OFF')
        check(settings.save_http_port(port.to_s), 'save free port')
        check(settings.save_http_enabled(true), 'enable failed')
        checkpoint('enabled', true)

        # The host sends a request which Ruby deliberately does not drain.
        File.open('checkpoint', 'wb') { |file| file.write('pending') }
        wait_for { ModLoader.http_inflight_count > 0 }
        check(settings.save_http_enabled(false), 'disable with pending request failed')
        check(ModLoader.http_inflight_count == 0 && ModLoader.http_poll.nil?, 'OFF retained requests')
        checkpoint('stopped')

        16.times do
          check(settings.save_http_enabled(true), 'rapid enable failed')
          check(settings.save_http_enabled(false), 'rapid disable failed')
        end
        check(settings.save_http_enabled(true), 're-enable failed')
        checkpoint('re-enabled', true)
        check(settings.save_http_port(next_port.to_s), 'save next port')
        check(http.port == port, 'editing the port restarted the active server')
        check(settings.save_http_enabled(false), 'port switch disable failed')
        check(settings.save_http_enabled(true) && http.port == next_port, 'new port not applied')
        checkpoint('new-port', true)
        # Reload while a different port is pending. The before_reload callback
        # must close the old listener before rebuilding Ruby routing state.
        check(settings.save_http_port(port.to_s), 'save reload port')
        ModResetter.restore_snapshot
        ModResetter.execute_all_scripts # clears component guards; fixture scripts dir is empty
        ['core/nvram.rb', 'input/settings.rb', 'http/router.rb'].each do |component|
          path = File.join(base, component)
          eval(File.read(path), TOPLEVEL_BINDING, path)
        end
        http.get('/ping') { { 'ok' => true } }
        http.tick
        check(http.running? && http.port == port, 'reload did not replace the old listener')
        checkpoint('reloaded', true)
        check(settings.save_http_enabled(false), 'post-reload disable')
        check(settings.save_http_port(next_port.to_s), 'restore next port')
        check(settings.save_http_enabled(true), 'post-reload enable')
        saved = ModLoader::NVRAMStore.new(File.join(ModLoader.data_directory, 'nvram.dat'))
        check(saved.section(:input)[:http_enabled] == true, 'ON not persisted')
      elsif phase == 'restore-on'
        check(settings.http_enabled?, 'saved ON lost at process restart')
        http.tick
        check(http.running?, 'saved ON did not start server')
        checkpoint('restored-on', true)
        check(settings.save_http_enabled(false), 'could not save OFF')
        checkpoint('saved-off')
      else
        check(!settings.http_enabled?, 'saved OFF lost at process restart')
        5.times { http.tick }
        check(!http.running?, 'saved OFF started server')
        checkpoint('restored-off')
      end
      File.open('result', 'wb') { |file| file.write('PASS') }
    rescue Exception => error
      File.open('result', 'wb') { |file| file.write("FAIL: #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") }
    ensure
      ModLoader::Http.stop if defined?(ModLoader::Http)
    end
  end
end

module SceneManager
  def self.run; HttpToggleRGSS.run; end
end
rgss_main { SceneManager.run }
