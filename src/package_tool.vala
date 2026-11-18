namespace Singularity.Apps.Store {

    public class PackageTool : Object {
        private const string ORIGIN = "flatpak/flathub/";
        private const string FLATPAK = "flatpak/";
        private static HashTable<string, string>? origins = null;
        private static HashTable<string, Json.Object>? sources = null;
        private static Mutex sources_lock;
        private static int probed = -1;
        private static string[] capabilities = {};
        private static HashTable<string, string>? requested = null;

        private static Mutex probe_lock;

        public static bool cpak () {
            if (AtomicInt.get (ref probed) >= 0) return AtomicInt.get (ref probed) == 1;
            probe_lock.lock ();
            if (probed < 0) AtomicInt.set (ref probed, probe () ? 1 : 0);
            probe_lock.unlock ();
            return probed == 1;
        }

        private static Json.Node? run_json (string[] argv) {
            string out_str = "";
            int status = 0;
            try {
                Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL, null, out out_str, null, out status);
                if (status != 0) return null;
                var parser = new Json.Parser ();
                parser.load_from_data (out_str);
                return parser.get_root ();
            } catch (Error e) {
                return null;
            }
        }

        private static bool probe () {
            var root = run_json ({ "cpak", "capabilities", "--json" });
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return false;
            var caps = root.get_object ().get_array_member ("capabilities");
            if (caps == null) return false;
            string[] have = {};
            caps.foreach_element ((a, i, node) => have += node.get_string ());
            capabilities = have;
            if (!("flatpak-install" in have && "flatpak-update" in have
                && "list-json" in have && "update-check" in have && "json-progress" in have)) return false;
            if (!has_flatpak ()) return true;
            var doctor = run_json ({ "cpak", "doctor", "--json" });
            return doctor != null && doctor.get_node_type () == Json.NodeType.OBJECT
                && doctor.get_object ().get_boolean_member_with_default ("ready", false);
        }

        private static bool has_flatpak () {
            return Environment.find_program_in_path ("flatpak") != null;
        }

        public static bool legacy (string app_id) {
            return !cpak () || (has_flatpak () && app_id in flatpak_ids ());
        }

        private static string[] flatpak_ids () {
            return lines_of ("flatpak --user list --app --columns=application");
        }

        public static string origin (string app_id) {
            sources_lock.lock ();
            string? known = origins != null ? origins.lookup (app_id) : null;
            sources_lock.unlock ();
            return known ?? ORIGIN + app_id;
        }

        private static string? app_of (string origin) {
            if (!origin.has_prefix (FLATPAK)) return null;
            var parts = origin.substring (FLATPAK.length).split ("/");
            return parts.length == 2 && parts[0] != "" && parts[1] != "" ? parts[1] : null;
        }

        private static string? id_of (Json.Object app) {
            var origin = app.get_string_member_with_default ("origin", "").down ();
            var id = app_of (origin);
            if (id == null) return null;
            var name = app.get_string_member_with_default ("name", "");
            var result = name.down () == id ? name : id;
            remember_origin (result, origin);
            return result;
        }

        private static void remember_origin (string app_id, string origin) {
            sources_lock.lock ();
            if (origins == null) origins = new HashTable<string, string> (str_hash, str_equal);
            origins.insert (app_id, origin);
            sources_lock.unlock ();
        }

        public static bool manages_sources () {
            return cpak () && "flatpak-remotes" in capabilities;
        }

        public static string sources_key () {
            if (!manages_sources ()) return "";
            var root = run_json ({ "cpak", "remote", "list", "--json" });
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return "";
            var key = new StringBuilder ();
            root.get_array ().foreach_element ((a, i, node) => {
                var remote = node.get_object ();
                if (remote == null || remote.get_boolean_member_with_default ("builtin", false)) return;
                key.append_printf ("%s %s\n", remote.get_string_member_with_default ("name", ""), remote.get_string_member_with_default ("url", ""));
            });
            return key.str;
        }

        public static Gee.ArrayList<Json.Object> source_apps () {
            var apps = new Gee.ArrayList<Json.Object> ();
            var found = new HashTable<string, Json.Object> (str_hash, str_equal);
            if (!manages_sources ()) return apps;
            var root = run_json ({ "cpak", "remote", "list", "--json" });
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return apps;
            root.get_array ().foreach_element ((a, i, node) => {
                var remote = node.get_object ();
                if (remote == null || remote.get_boolean_member_with_default ("builtin", false)) return;
                var name = remote.get_string_member_with_default ("name", "");
                var title = remote.get_string_member_with_default ("title", name);
                var listed = run_json ({ "cpak", "remote", "apps", name, "--json" });
                if (listed == null || listed.get_node_type () != Json.NodeType.ARRAY) return;
                listed.get_array ().foreach_element ((b, j, item) => {
                    var app = item.get_object ();
                    if (app == null) return;
                    var id = app.get_string_member_with_default ("id", "");
                    if (id == "" || found.contains (id)) return;
                    app.set_string_member ("source_title", title);
                    found.insert (id, app);
                    apps.add (app);
                    remember_origin (id, app.get_string_member_with_default ("origin", ORIGIN + id.down ()));
                });
            });
            sources_lock.lock ();
            sources = found;
            sources_lock.unlock ();
            return apps;
        }

        private static Json.Object? source_of (string app_id) {
            sources_lock.lock ();
            Json.Object? app = sources != null ? sources.lookup (app_id) : null;
            sources_lock.unlock ();
            return app;
        }

        public static string? requested_permissions (string app_id) {
            return requested != null ? requested.lookup (app_id) : null;
        }

        private static bool can_approve () {
            return "update-approve-permissions" in capabilities;
        }

        public static void ensure_remote () {
            if (cpak ()) return;
            try {
                Process.spawn_command_line_async (
                    "flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo");
            } catch (Error e) {
                warning ("flathub remote-add: %s", e.message);
            }
        }

        public static string[] install_argv (string app_id) {
            var source = cpak () ? source_of (app_id) : null;
            if (source != null) {
                string[] argv = { "cpak", "install", "--flatpak", app_id, "--flatpak-remote", source.get_string_member_with_default ("remote", "") };
                var branch = source.get_string_member_with_default ("branch", "");
                if (branch != "") {
                    argv += "--branch";
                    argv += branch;
                }
                argv += "--json-progress";
                argv += "-y";
                return argv;
            }
            if (cpak ()) return { "cpak", "install", "--flatpak", app_id, "--json-progress", "-y" };
            return { "flatpak", "--user", "install", "-y", "--noninteractive", "flathub", app_id };
        }

        public static string[] remove_argv (string app_id) {
            if (!legacy (app_id)) return { "cpak", "remove", origin (app_id) };
            return { "flatpak", "--user", "uninstall", "-y", app_id };
        }

        public static string[] update_argv (string app_id) {
            if (!legacy (app_id) && can_approve () && requested_permissions (app_id) != null)
                return { "cpak", "update", origin (app_id), "--json-progress", "--approve-permissions" };
            if (!legacy (app_id)) return { "cpak", "update", origin (app_id), "--json-progress", "-n" };
            return { "flatpak", "--user", "update", "-y", app_id };
        }

        public static string[] update_all_argv (bool use_cpak, bool approve) {
            if (use_cpak && approve && can_approve ()) return { "cpak", "update", "--json-progress", "--approve-permissions" };
            if (use_cpak) return { "cpak", "update", "--json-progress", "-n" };
            return { "flatpak", "--user", "update", "-y" };
        }

        public static bool[] update_all_tools () {
            if (!cpak ()) return { false };
            if (has_flatpak ()) return { true, false };
            return { true };
        }

        public static string[] run_argv (string app_id) {
            if (!legacy (app_id)) return { "cpak", "run", origin (app_id) };
            return { "flatpak", "run", app_id };
        }

        private static string[] lines_of (string cmd) {
            string out_str = "";
            int status = 0;
            try {
                Process.spawn_command_line_sync (cmd, out out_str, null, out status);
            } catch (Error e) {
                warning ("%s: %s", cmd, e.message);
            }
            string[] ids = {};
            if (out_str == null) return ids;
            foreach (var line in out_str.split ("\n")) {
                var id = line.strip ();
                if (id != "" && !(id in ids)) ids += id;
            }
            return ids;
        }

        public static string[] installed_ids () {
            if (!cpak ()) return lines_of ("flatpak --user list --columns=application");
            string[] ids = has_flatpak () ? flatpak_ids () : new string[0];
            var root = run_json ({ "cpak", "list", "--json" });
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return ids;
            root.get_array ().foreach_element ((a, i, node) => {
                var app = node.get_object ();
                if (app == null || !app.has_member ("flatpak") || app.get_null_member ("flatpak")) return;
                if (app.has_member ("pulled_in") && app.get_boolean_member ("pulled_in")) return;
                var id = id_of (app);
                if (id != null && !(id in ids)) ids += id;
            });
            return ids;
        }

        public static string[] update_ids () {
            if (!cpak ()) return lines_of ("flatpak --user remote-ls --updates --columns=application");
            string[] ids = has_flatpak () ? lines_of ("flatpak --user remote-ls --updates --columns=application") : new string[0];
            requested = new HashTable<string, string> (str_hash, str_equal);
            var root = run_json ({ "cpak", "update", "--check", "--json" });
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return ids;
            root.get_array ().foreach_element ((a, i, node) => {
                var r = node.get_object ();
                if (r == null || r.get_string_member_with_default ("status", "") != "available") return;
                var id = id_of (r);
                if (id == null || id in ids) return;
                ids += id;
                var member = r.get_member ("permission_additions");
                if (member == null || member.get_node_type () != Json.NodeType.ARRAY) return;
                var additions = member.get_array ();
                if (additions.get_length () == 0) return;
                string[] names = {};
                additions.foreach_element ((b, j, item) => names += item.get_string ());
                requested.insert (id, string.joinv (", ", names));
            });
            return ids;
        }

        public static int progress_percent (string line, out string? error, out string? status) {
            error = null;
            status = null;
            if (!line.has_prefix ("{")) return -1;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (line);
                var ev = parser.get_root ().get_object ();
                var phase = ev.get_string_member_with_default ("phase", "");
                if (phase == "done") {
                    var msg = ev.get_string_member_with_default ("error", "");
                    if (msg != "") error = msg;
                    return 100;
                }
                var total = ev.get_int_member_with_default ("objects_total", 0);
                var done = ev.get_int_member_with_default ("objects_done", 0);
                int percent = total <= 0 ? 0 : (int) (done * 100 / total).clamp (0, 100);
                status = progress_status (phase, ev.get_string_member_with_default ("ref", ""), done, total, ev.get_int_member_with_default ("bytes_done", 0));
                return percent;
            } catch (Error e) {
                return -1;
            }
        }

        private static string progress_status (string phase, string @ref, int64 done, int64 total, int64 bytes) {
            string what;
            switch (phase) {
            case "resolve":
                what = _("Resolving");
                break;
            case "download":
                what = _("Downloading");
                break;
            case "install":
                what = _("Installing");
                break;
            default:
                what = phase;
                break;
            }
            var parts = new StringBuilder (what);
            if (@ref != "") parts.append (" " + @ref);
            if (total > 0) parts.append_printf (" %lld/%lld", done, total);
            if (bytes > 0) parts.append (" " + GLib.format_size ((uint64) bytes));
            return parts.str;
        }
    }
}
