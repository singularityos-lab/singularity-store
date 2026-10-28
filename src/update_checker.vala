namespace Singularity.Apps.Store {

    public class UpdateChecker : GLib.Application {
        private const uint CHECK_INTERVAL = 6 * 60 * 60;
        private const uint FIRST_CHECK_DELAY = 30;
        private const uint DOCK_SETTLE_DELAY = 5;

        private int last_count = 0;
        private bool checking = false;
        private SxiClient sxi = new SxiClient ();

        public UpdateChecker () {
            Object (application_id: "dev.sinty.store.Updates", flags: ApplicationFlags.IS_SERVICE);
        }

        protected override void startup () {
            base.startup ();
            hold ();
            Timeout.add_seconds (FIRST_CHECK_DELAY, () => {
                check ();
                return Source.REMOVE;
            });
            Timeout.add_seconds (CHECK_INTERVAL, () => {
                check ();
                return Source.CONTINUE;
            });
            Bus.watch_name_on_connection (get_dbus_connection (), "dev.sinty.Dock",
                BusNameWatcherFlags.NONE, () => {
                    Timeout.add_seconds (DOCK_SETTLE_DELAY, () => {
                        if (last_count > 0) UpdateBadge.publish (get_dbus_connection (), last_count);
                        return Source.REMOVE;
                    });
                }, null);
        }

        protected override void activate () {
            check ();
        }

        private void check () {
            if (checking) return;
            checking = true;
            new Thread<bool> ("store-update-check", () => {
                int count = UpdateBadge.list_update_ids ().length;
                Idle.add (() => {
                    count_sxi.begin ((obj, res) => {
                        count += count_sxi.end (res);
                        checking = false;
                        last_count = count;
                        UpdateBadge.publish (get_dbus_connection (), count);
                    });
                    return Source.REMOVE;
                });
                return true;
            });
        }

        private async int count_sxi () {
            if (!sxi.available) yield sxi.open ();
            return SxiClient.update_ids (yield sxi.list_available ()).length;
        }
    }

    public static int main (string[] args) {
        return new UpdateChecker ().run (args);
    }
}
