namespace Singularity.Apps.Store {

    public class PackageTool : Object {
        private const string ORIGIN = "flatpak/flathub/";
        private static int probed = -1;

        public static bool cpak () {
            if (probed < 0) probed = probe () ? 1 : 0;
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
            return ORIGIN + app_id;
        }

        private static string? app_of (string origin) {
            return origin.has_prefix (ORIGIN) ? origin.substring (ORIGIN.length) : null;
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
            if (cpak ()) return { "cpak", "install", "--flatpak", app_id, "--json-progress", "-y" };
            return { "flatpak", "--user", "install", "-y", "--noninteractive", "flathub", app_id };
        }

        public static string[] remove_argv (string app_id) {
            if (!legacy (app_id)) return { "cpak", "remove", origin (app_id) };
            return { "flatpak", "--user", "uninstall", "-y", app_id };
        }

        public static string[] update_argv (string app_id) {
            if (!legacy (app_id)) return { "cpak", "update", origin (app_id), "--json-progress", "-n" };
            return { "flatpak", "--user", "update", "-y", app_id };
        }

        public static string[] update_all_argv (bool use_cpak) {
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
                var id = app_of (app.get_string_member_with_default ("origin", ""));
                if (id != null && !(id in ids)) ids += id;
            });
            return ids;
        }

        public static string[] update_ids () {
            if (!cpak ()) return lines_of ("flatpak --user remote-ls --updates --columns=application");
            string[] ids = has_flatpak () ? lines_of ("flatpak --user remote-ls --updates --columns=application") : new string[0];
            var root = run_json ({ "cpak", "update", "--check", "--json" });
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return ids;
            root.get_array ().foreach_element ((a, i, node) => {
                var r = node.get_object ();
                if (r == null || r.get_string_member_with_default ("status", "") != "available") return;
                var id = app_of (r.get_string_member_with_default ("origin", ""));
                if (id != null && !(id in ids)) ids += id;
            });
            return ids;
        }

        public static int progress_percent (string line, out string? error) {
            error = null;
            if (!line.has_prefix ("{")) return -1;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (line);
                var ev = parser.get_root ().get_object ();
                if (ev.get_string_member_with_default ("phase", "") == "done") {
                    var msg = ev.get_string_member_with_default ("error", "");
                    if (msg != "") error = msg;
                    return 100;
                }
                var total = ev.get_int_member_with_default ("objects_total", 0);
                if (total <= 0) return 0;
                return (int) (ev.get_int_member_with_default ("objects_done", 0) * 100 / total).clamp (0, 100);
            } catch (Error e) {
                return -1;
            }
        }
    }
}
