using Gtk;
using Gdk;
using Pango;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps.Store {

    public class AppInfo : Object {
        public string app_id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string summary { get; set; default = ""; }
        public string developer { get; set; default = ""; }
        public string? icon_url { get; set; default = null; }
        public bool is_installed { get; set; default = false; }
        public string? version_str { get; set; default = null; }
        public string? description { get; set; default = null; }
        public string? category { get; set; default = null; }
        public string[] permissions { get; set; default = {}; }
        public string[] screenshot_urls { get; set; default = {}; }
    }
}
