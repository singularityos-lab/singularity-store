namespace Singularity.Apps.Store {

    public class WebEntry : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string url { get; set; default = ""; }
        public string icon { get; set; default = ""; }
        public string summary { get; set; default = ""; }
        public string form_factors { get; set; default = ""; }
        public string category { get; set; default = ""; }
        public bool pinned { get; set; default = false; }

        public string app_id {
            owned get { return WebCatalog.ID_PREFIX + id; }
        }

        public string host {
            owned get {
                try {
                    return Uri.parse (url, UriFlags.NONE).get_host () ?? url;
                } catch (Error e) {
                    return url;
                }
            }
        }

        public bool supports (Singularity.FormFactorKind kind) {
            foreach (var part in form_factors.split (";")) {
                if (part.strip ().down () == kind.to_id ()) return true;
            }
            return false;
        }

        public string desktop_path () {
            return Path.build_filename (Environment.get_user_data_dir (), "applications", app_id + ".desktop");
        }

        public bool installed {
            get { return FileUtils.test (desktop_path (), FileTest.EXISTS); }
        }
    }

    public class WebCatalog : Object {
        public const string ID_PREFIX = "dev.sinty.browser.WebApp_";
        private const string REMOTE = "https://raw.githubusercontent.com/singularityos-lab/singularity-store/main/data/webapps.json";
        private const string BUNDLED = "/dev/sinty/store/webapps.json";

        private GenericArray<WebEntry> _entries = new GenericArray<WebEntry> ();

        public signal void changed ();

        public WebCatalog () {
            try {
                var bytes = resources_lookup_data (BUNDLED, ResourceLookupFlags.NONE);
                parse ((string) bytes.get_data ());
            } catch (Error e) {
                warning ("web catalog: %s", e.message);
            }
        }

        public async void refresh (Soup.Session session) {
            try {
                var message = new Soup.Message ("GET", REMOTE);
                var bytes = yield session.send_and_read_async (message, Priority.LOW, null);
                if (message.status_code != 200) return;
                var copy = new uint8[bytes.get_size () + 1];
                Memory.copy (copy, bytes.get_data (), bytes.get_size ());
                if (parse ((string) copy)) changed ();
            } catch (Error e) {
            }
        }

        private bool parse (string json) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (json);
            } catch (Error e) {
                return false;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return false;
            var obj = root.get_object ();
            if (!obj.has_member ("apps")) return false;
            var next = new GenericArray<WebEntry> ();
            foreach (var node in obj.get_array_member ("apps").get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = node.get_object ();
                var e = new WebEntry ();
                e.id = o.get_string_member_with_default ("id", "");
                e.name = o.get_string_member_with_default ("name", "");
                e.url = o.get_string_member_with_default ("url", "");
                if (!valid (e.id) || e.name == "" || !e.url.has_prefix ("https://")) continue;
                e.icon = o.get_string_member_with_default ("icon", "");
                e.summary = o.get_string_member_with_default ("summary", "");
                e.form_factors = o.get_string_member_with_default ("form_factors", "desktop;tablet;phone");
                e.category = o.get_string_member_with_default ("category", "");
                e.pinned = o.get_boolean_member_with_default ("pinned", false);
                next.add (e);
            }
            if (next.length == 0) return false;
            _entries = next;
            return true;
        }

        private static bool valid (string id) {
            if (id == "" || id.length > 60) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!(c.isalnum () || c == '_')) return false;
            }
            return true;
        }

        public GenericArray<WebEntry> ranked (Singularity.FormFactorKind kind) {
            var list = new GenericArray<WebEntry> ();
            foreach (var e in _entries) list.add (e);
            list.sort_with_data ((a, b) => rank (a, kind) - rank (b, kind));
            return list;
        }

        private static int rank (WebEntry e, Singularity.FormFactorKind kind) {
            int r = 0;
            if (!e.supports (kind)) r += 2;
            if (!e.pinned) r += 1;
            return r;
        }

        public WebEntry? find (string app_id) {
            foreach (var e in _entries) {
                if (e.app_id == app_id) return e;
            }
            return null;
        }

        public GenericArray<WebEntry> highlights (Singularity.FormFactorKind kind) {
            var list = new GenericArray<WebEntry> ();
            foreach (var e in ranked (kind)) {
                if (e.pinned && e.supports (kind)) list.add (e);
            }
            return list;
        }

        private static string? browser_executable () {
            var info = new GLib.DesktopAppInfo ("dev.sinty.browser.desktop");
            if (info != null) {
                string? exe = info.get_executable ();
                if (exe != null && Path.is_absolute (exe) && FileUtils.test (exe, FileTest.IS_EXECUTABLE)) return exe;
            }
            return Environment.find_program_in_path ("singularity-browser");
        }

        public void install (WebEntry entry, owned SourceFunc? done, out string? error) {
            error = null;
            string? exe = browser_executable ();
            if (exe == null) {
                error = _("The Browser is not installed");
                return;
            }
            try {
                Pid pid;
                Process.spawn_async (null, { exe, "--install-webapp", entry.app_id, entry.url, entry.name, entry.form_factors, entry.icon },
                    null, SpawnFlags.DO_NOT_REAP_CHILD | SpawnFlags.STDOUT_TO_DEV_NULL, null, out pid);
                ChildWatch.add (pid, (p, status) => {
                    Process.close_pid (p);
                    if (done != null) done ();
                });
            } catch (SpawnError e) {
                error = e.message;
            }
        }

        public void uninstall (WebEntry entry) {
            string? exe = browser_executable ();
            if (exe == null) return;
            try {
                Process.spawn_sync (null, { exe, "--uninstall-webapp", entry.app_id }, null, SpawnFlags.STDOUT_TO_DEV_NULL, null, null, null, null);
            } catch (SpawnError e) {
            }
        }

        public void open (WebEntry entry) {
            var info = new GLib.DesktopAppInfo.from_filename (entry.desktop_path ());
            if (info == null) return;
            try {
                info.launch (null, null);
            } catch (Error e) {
                warning ("web app launch: %s", e.message);
            }
        }
    }
}
