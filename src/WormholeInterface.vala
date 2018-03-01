using GLib;

public class WormholeInterface : Object {

	int pid = -1;

	public signal void errored (string err);
	public signal void ready_to_send (string id);
	public signal void progress (int percent);
	public signal void started ();
	public signal void finished (bool isSuccessful);
	public signal void closed ();

	public string home_path = null;
	public string wormhole_path = null;
	public string downloads_path = null;
	public const string[] WORMHOLE_LOCATIONS = {"/bin/wormhole", "/usr/sbin/wormhole", "~/.local/bin/wormhole"};

	public const string ERR_INVALID_ID = "reenter the key";
	public const string ERR_CROWDED = "crowded";
	public const string ERR_REJECTED = "transfer rejected";
	public const string ERR_ALREADY_EXISTS = "overwrite existing";
	public const string ERR_MISMATCHED_ID = "confirmation failed";
	public const string ID_GENERATED = "wormhole receive";
	public const string FINISH_RECEIVE = "Received file written";
	public const string PERCENT_RECEIVE = "%|";

	construct{
		home_path = GLib.Environment.get_home_dir ();
		downloads_path = home_path + "/Downloads/";
	}

	public bool bin_present(){
		var found = false;

		foreach (var path in WORMHOLE_LOCATIONS) {
			try{
				string[] env = Environ.get ();
				string[] cmd = {path.replace ("~", home_path), "--version"};
				Process.spawn_sync (home_path, cmd, env, SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, null);
				found = true;
				wormhole_path = path;
				info ("Found magic-wormhole at: "+wormhole_path);
			}
			catch (SpawnError e){}
		}

		if(!found)
			info ("Can't find magic-wormhole");

		return found;
	}

	public bool install(){
		started ();
		try{
			Process.spawn_command_line_sync ("pip install --user --no-input magic-wormhole");
		}
		catch (GLib.SpawnError e){
			warning(e.message);
			return false;
		}
		closed ();
		return bin_present ();
	}

	public bool is_running(){
		return pid > 0;
	}

	public void close(){
			if(!is_running ()) return;
			try {
				info ("Closing wormhole with PID "+ pid.to_string ());
				Process.spawn_command_line_sync ("kill " + pid.to_string ());
				pid = -1;
				closed ();
			} catch (SpawnError e) {
				warning ("Can't close wormhole: %s\n", e.message);
			}		
	}

	public void open(string[] argv, string work_dir){
		if (is_running ()) return;

		int standard_err;
		int standard_out;

		info("Opening wormhole");
		started ();

		try{
		    Process.spawn_async_with_pipes (
		        work_dir,
		        argv,
		        null,
		        SpawnFlags.SEARCH_PATH,
		        null,
		        out pid,
		        null,
		        out standard_out,
		        out standard_err);

			var channel_out = new IOChannel.unix_new (standard_out);
			channel_out.add_watch (IOCondition.IN | IOCondition.HUP, (channel, condition) => {
				return process_line (channel, condition);
			});
			var channel_err = new IOChannel.unix_new (standard_err);
			channel_err.add_watch (IOCondition.IN | IOCondition.HUP, (channel, condition) => {
				return process_line (channel, condition);
			});
		}
		catch(GLib.SpawnError e){
			errored(e.message);
			closed();
		}

	}

	public void send(string file){
		open ({wormhole_path.replace ("~", home_path), "send", file}, home_path);
	}
	public void receive(string id){
		open ({wormhole_path.replace ("~", home_path), "receive", "--accept-file", id}, downloads_path);
	}

	private bool process_line (IOChannel channel, IOCondition condition) {
		if(condition == IOCondition.HUP){
			if(is_running ()){
				debug (">>STREAM END<<");
				close ();
			}
			return false;
		}

		try {
			string line;
			channel.read_line (out line, null, null);
			debug ("%s> %s", condition.to_string(), line);

			if(ERR_INVALID_ID in line){
				errored ("Incorrect ID.");
				close ();
				finished (false);
				return false;
			}
			if(ERR_MISMATCHED_ID in line){
				errored ("ID confirmation failed. Did you type it wrong?");
				close ();
				finished (false);
				return false;
			}
			if(ERR_CROWDED in line){
				errored ("Server denied connection. Check your ID validity or try a bit later.");
				close ();
				finished (false);
				return false;
			}
			if(ERR_ALREADY_EXISTS in line){
				errored ("There already is a file with the same name in the Downloads folder.");
				close ();
				finished (false);
				return false;
			}
			if(ERR_REJECTED in line){
				close ();
				finished (false);
				return false;
			}

			if(PERCENT_RECEIVE in line){
				var percent = line.split ("%", 2) [0];
				progress (int.parse (percent));
			}
			if(ID_GENERATED in line){
				var id = line.split (" ", 3)[2];
				ready_to_send (id.strip ().replace ("\n",""));
				return false;
			}
			if(FINISH_RECEIVE in line){
				close ();
				finished (true);
			}


		} catch (IOChannelError e) {
			warning ("IOChannelError: %s\n", e.message);
			return false;
		} catch (ConvertError e) {
			warning ("ConvertError: %s\n", e.message);
			return false;
		}

		while (Gtk.events_pending ())
			Gtk.main_iteration ();

		return true;
	}

}