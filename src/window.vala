using Gtk;
using Gdk;
using Pango;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps.Store {

    [GtkTemplate(ui = "/dev/sinty/store/ui/main.ui")]
    public class StoreWindow : Singularity.Widgets.Window {

        [GtkChild] public unowned Stack main_stack;

        public Singularity.Widgets.AppSidebar sidebar;

        public StoreWindow(Gtk.Application app) {
            Object(application: app);
            set_title("Store");
            set_default_size(1100, 720);
            toolbar.is_static = true;

            sidebar = new Singularity.Widgets.AppSidebar();
        }
    }
}