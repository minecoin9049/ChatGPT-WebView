(function () {
  'use strict';
  if (location.hostname !== 'chatgpt.com' || window.__mobileShellInstalled) return;
  window.__mobileShellInstalled = true;
  var route = '', stableAfter = 0, timer = 0, last = '', enabled = true;
  function post(value) {
    try { window.webkit.messageHandlers.mobileShell.postMessage(value); } catch (_) {}
  }
  function chatID() {
    if (new URLSearchParams(location.search).get('temporary-chat') === 'true') return null;
    var m = location.pathname.match(/^\/c\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/?$/i);
    return m ? m[1].toLowerCase() : null;
  }
  function updateRoute() {
    var next = location.pathname + location.search;
    if (next !== route) {
      route = next; stableAfter = Date.now() + 3000; last = '';
      post({kind: 'route', id: chatID() || ''});
    }
  }
  function capture() {
    timer = 0;
    updateRoute();
    var id = chatID();
    if (!enabled || !id || Date.now() < stableAfter) return;
    var nodes = document.querySelectorAll('main [data-message-author-role]');
    var messages = [];
    // Limit the work as well as disk usage on small-memory iPhones.
    for (var i = Math.max(0, nodes.length - 80); i < nodes.length; i++) {
      var node = nodes[i], role = node.getAttribute('data-message-author-role');
      if (role !== 'user' && role !== 'assistant') continue;
      var text = (node.innerText || '').trim().slice(0, 12000);
      if (text) messages.push({role: role, text: text});
    }
    if (!messages.length) return;
    // Save only loaded text, never composer drafts, images, hidden account data or network responses.
    var title = (messages.find(function (m) { return m.role === 'user'; }) || messages[0]).text.slice(0, 100);
    var packet = {kind: 'snapshot', id: id, title: title, messages: messages};
    var signature = JSON.stringify(packet);
    if (signature !== last) { last = signature; post(packet); }
  }
  function schedule() {
    updateRoute();
    if (timer) clearTimeout(timer);
    // Streaming tokens are coalesced; no full DOM scan per token and no polling loop.
    timer = setTimeout(capture, Math.max(1800, stableAfter - Date.now() + 50));
  }
  window.__setChatCacheEnabled = function (value) { enabled = !!value; last = ''; if (enabled) schedule(); };
  window.__captureChatCache = capture;
  ['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name];
    history[name] = function () { var value = original.apply(this, arguments); schedule(); return value; };
  });
  addEventListener('popstate', schedule);
  addEventListener('pagehide', capture);
  document.addEventListener('visibilitychange', function () { if (document.hidden) capture(); else schedule(); });
  function isLogout(value) {
    try { return /\/(logout|signout)(\/|$)/i.test(new URL(value, location.href).pathname); } catch (_) { return false; }
  }
  function logout() { enabled = false; last = ''; post({kind: 'logout'}); }
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href]');
    if (a && isLogout(a.href)) logout();
  }, true);
  var originalFetch = window.fetch;
  window.fetch = function (input) {
    if (isLogout(typeof input === 'string' ? input : input && input.url)) logout();
    return originalFetch.apply(this, arguments);
  };
  function start() {
    var style = document.createElement('style');
    style.textContent = 'html,body{overscroll-behavior-x:none}button,[role="button"]{touch-action:manipulation}textarea,[contenteditable="true"]{font-size:max(16px,1em)}';
    document.head.appendChild(style);
    function theme() {
      var root = document.documentElement;
      var dark = root.classList.contains('dark') || root.getAttribute('data-theme') === 'dark';
      post({kind: 'theme', dark: dark});
    }
    new MutationObserver(theme).observe(document.documentElement, {attributes:true, attributeFilter:['class','data-theme']});
    theme();
    var observer = new MutationObserver(schedule);
    observer.observe(document.body, {subtree: true, childList: true, characterData: true});
    schedule();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true}); else start();
})();
