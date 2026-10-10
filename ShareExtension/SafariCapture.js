// Safari runs this on the page Ian is looking at when he taps Share, then Shelf.
// It hands back the page exactly as shown, so articles from sites he's signed in to come through in full.
var ExtensionPreprocessingJS = {
  run: function (args) {
    var html = "";
    try {
      html = document.documentElement.outerHTML;
      if (html.length > 6000000) html = "";
    } catch (e) {
      html = "";
    }
    args.completionFunction({ url: document.URL, title: document.title, html: html });
  },
  finalize: function (args) {}
};
