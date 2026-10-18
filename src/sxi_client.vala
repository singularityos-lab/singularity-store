namespace Singularity.Apps.Store {

    public class SxiClient : Object {
        private const string BUS_NAME = "dev.sinty.SXI1";
        private const string OBJECT_PATH = "/dev/sinty/SXI1";

        private DBusProxy? proxy = null;

        public signal void changed ();
        public signal void progress (string app_id, string stage, int64 done, int64 total);
        public signal void finished (string app_id, string error);

        public bool available {
            get { return proxy != null && proxy.g_name_owner != null; }
        }

        public async void open () {
            var bus = Environment.get_variable ("SXI_BUS") == "session" ? BusType.SESSION : BusType.SYSTEM;
            try {
                proxy = yield new DBusProxy.for_bus (bus, DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
                    null, BUS_NAME, OBJECT_PATH, BUS_NAME, null);
                proxy.g_signal.connect (on_signal);
                proxy.notify["g-name-owner"].connect (() => changed ());
            } catch (Error e) {
                proxy = null;
                debug ("SXI daemon unavailable: %s", e.message);
            }
        }

        private void on_signal (string? sender, string name, Variant parameters) {
            switch (name) {
                case "Changed":
                    changed ();
                    break;
                case "Progress":
                    string id, stage;
                    int64 done, total;
                    parameters.get ("(ssxx)", out id, out stage, out done, out total);
                    progress (id, stage, done, total);
                    break;
                case "Finished":
                    string id, error;
                    parameters.get ("(ss)", out id, out error);
                    finished (id, error);
                    break;
            }
        }

        private async Json.Array? list (string method) {
            if (!available) return null;
            try {
                var reply = yield proxy.call (method, null, DBusCallFlags.NONE, -1, null);
                string data;
                reply.get ("(s)", out data);
                var parser = new Json.Parser ();
                parser.load_from_data (data);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return new Json.Array ();
                return root.get_array ();
            } catch (Error e) {
                warning ("SXI %s: %s", method, e.message);
                return null;
            }
        }

        public async Json.Array? list_available () {
            return yield list ("ListAvailable");
        }

        public async Json.Array? list_installed () {
            return yield list ("ListInstalled");
        }

        public async void refresh () throws Error {
            if (!available) return;
            yield proxy.call ("Refresh", null, DBusCallFlags.NONE, 180000, null);
        }

        public async void install (string app_id) throws Error {
            yield proxy.call ("Install", new Variant ("(s)", app_id), DBusCallFlags.NONE, -1, null);
        }

        public async void remove (string app_id) throws Error {
            yield proxy.call ("Remove", new Variant ("(s)", app_id), DBusCallFlags.NONE, -1, null);
        }
    }
}
