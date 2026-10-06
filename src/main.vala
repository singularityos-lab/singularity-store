int main (string[] args) {
    var app = new Singularity.Apps.Store.StoreApp ();
    new Singularity.Apps.Store.StoreSearchProvider (app).export (app);
    return app.run (args);
}
