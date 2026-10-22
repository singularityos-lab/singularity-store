namespace Singularity.Apps.Store {

    public class UpdateBadge : Object {
        public const string DESKTOP_URI = "application://dev.sinty.store.desktop";

        public static string[] list_update_ids () {
            return PackageTool.update_ids ();
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
