(function() {
  var THRESHOLD = 60;
  var TRACKING_TID;

  Convos.mixin.messages = {
    watch: {
      "dialog.active": function(v, o) {
        if (!v) return;
        if (TRACKING_TID) clearTimeout(TRACKING_TID);
        TRACKING_TID = setInterval(this.trackViewPort, 200);
        this.atBottom = true;
      }
    },
    methods: {
      trackViewPort: function() {
        var self = this;
        var messages = this.$refs.messages || [];
        var el = this.scrollEl;
        var scrollTop = el.scrollTop;
        var totalHeight = el.scrollHeight;
        var breakTop = scrollTop + (window.innerHeight || document.documentElement.clientHeight);
        var diff = {totalHeight: totalHeight - this.totalHeight, scrollTop: scrollTop - this.scrollTop};

        if (!diff.totalHeight && !diff.scrollTop) return;
        if (!diff.totalHeight) this.atBottom = totalHeight - el.offsetHeight < scrollTop + THRESHOLD;
        if (DEBUG.scroll) console.log(["[scroll:" + this.dialog.dialog_id + "]", this.atBottom, messages.length, scrollTop + "-" + this.scrollTop, totalHeight + "-" + this.totalHeight].join(" "));
        if (this.atBottom) el.scrollTop = totalHeight;

        this.scrollTop = scrollTop;
        this.totalHeight = totalHeight;
        this.guard = 0;

        for (var i = 0; i < messages.length; i++) {
          var offsetTop = messages[i].$el.offsetTop;
          if (offsetTop > breakTop) break;
          if (offsetTop < scrollTop) continue;
          messages[i].$emit("visible");
        }

        if (diff.scrollTop && scrollTop < THRESHOLD) {
          this.dialog.load({historic: true}, function(err, body) {
            self.$nextTick(function() { el.scrollTop = scrollTop + el.scrollHeight - totalHeight });
          });
        }
      }
    },
    ready: function() {
      this.atBottom = true;
      this.totalHeight = 0;
      this.scrollTop = 0;
      this.scrollEl = this.$el.querySelector(".scroll-element");

      this.guard = 0;
      this.dialog.on("message", function() {
        if (this.dialog.visible && !this.guard++) this.$nextTick(this.trackViewPort);
      }.bind(this));
    },
    beforeDestroy: function() {
      if (this._trackTid) clearTimeout(this._trackTid);
    }
  };
})();
