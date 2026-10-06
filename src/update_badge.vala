namespace Singularity.Apps.Store {

    public class UpdateBadge : Object {
        public const string DESKTOP_URI = "application://dev.sinty.store.desktop";

        public static string[] list_update_ids () {
            string stdout_str = "";
            string stderr_str = "";
            int status_code   = 0;
            try {
                Process.spawn_command_line_sync (
                    "flatpak --user remote-ls --updates --columns=application",
                    out stdout_str, out stderr_str, out status_code);
            } catch (Error e) {
                warning ("Updates check error: %s", e.message);
            }

            string[] ids = {};
            foreach (var line in stdout_str.split ("\n")) {
                var trimmed = line.strip ();
                if (trimmed != "" && !(trimmed in ids)) ids += trimmed;
            }
            return ids;
        }

        public static void publish (DBusConnection? connection, int count) {
            if (connection == null) return;
            var props = new VariantBuilder (VariantType.VARDICT);
            props.add ("{sv}", "count", new Variant.int64 (count));
            props.add ("{sv}", "count-visible", new Variant.boolean (count > 0));
            try {
                connection.emit_signal (null,
                    "/com/canonical/Unity/LauncherEntry",
                    "com.canonical.Unity.LauncherEntry",
                    "Update",
                    new Variant ("(s@a{sv})", DESKTOP_URI, props.end ()));
            } catch (Error e) {
                warning ("Update badge error: %s", e.message);
            }
        }
    }
}
