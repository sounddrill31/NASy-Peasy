import subprocess
import os
from pyanaconda.ui.gui.spokes import NormalSpoke
from pyanaconda.ui.common import FirstbootSpokeMixIn
from pyanaconda.ui.gui.categories.system import SystemCategory
from pyanaconda.i18n import _

class NasySetupSpoke(FirstbootSpokeMixIn, NormalSpoke):
    mainWidgetName = "nasy_window"
    uiFile = "nasy.glade"
    category = SystemCategory
    icon = "preferences-system-symbolic"
    title = _("NASY-PEASY SETUP")

    @classmethod
    def should_run(cls, environment, data):
        return True

    def __init__(self, data, storage, payload):
        NormalSpoke.__init__(self, data, storage, payload)
        self._status = _("Configured")
        self.hostname_entry = None
        self.mdns_preview = None
        self.session_combo = None

    def initialize(self):
        NormalSpoke.initialize(self)
        self.hostname_entry = self.builder.get_object("hostname_entry")
        self.mdns_preview = self.builder.get_object("mdns_preview")
        self.session_combo = self.builder.get_object("session_combo")

        # Set defaults
        current_hostname = subprocess.check_output(["hostname"]).decode().strip()
        self.hostname_entry.set_text(current_hostname)
        self.session_combo.set_active_id("lxqt")

        # Connect signals
        self.hostname_entry.connect("changed", self._on_hostname_changed)

    def _on_hostname_changed(self, entry):
        hostname = entry.get_text()
        self.mdns_preview.set_text(_("mDNS Preview: %s.local") % hostname)

    def apply(self):
        """Save settings to the system."""
        hostname = self.hostname_entry.get_text()
        session = self.session_combo.get_active_id()

        # Set hostname
        subprocess.run(["hostnamectl", "set-hostname", hostname])

        # Set session
        subprocess.run(["/usr/bin/switch-session", "set", session])

    @property
    def completed(self):
        return True

    @property
    def status(self):
        return self._status
