// Stripe Purchase - Thank You Page Snippet
//
// Place this in a <script> tag before </body> on your thank-you page.
// Reads Stripe session_id from URL, collects all browser cookies and context,
// POSTs everything to sGTM where the Stripe Purchase Client template
// calls Stripe API and builds a full GA4-compatible purchase event.
//
// Requirements:
//   - Stripe Payment Link success URL must include ?session_id={CHECKOUT_SESSION_ID}
//   - sGTM must have the Stripe Purchase Client template imported and configured
//   - Update the fetch URL below to match your sGTM endpoint + request path

function getCookie(name) {
  const match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
  return match ? decodeURIComponent(match[2]) : null;
}

function getGaSessionCookie() {
  // Find the _ga_XXXXXX cookie (GA4 session cookie) - name varies per property
  const cookies = document.cookie.split(';');
  for (let i = 0; i < cookies.length; i++) {
    const c = cookies[i].trim();
    if (c.indexOf('_ga_') === 0 && c.indexOf('=') > 0) {
      const name = c.substring(0, c.indexOf('='));
      if (name !== '_ga') return getCookie(name);
    }
  }
  return null;
}

function cleanUrl() {
  const url = new URL(window.location.href);
  url.searchParams.delete('session_id');
  window.history.replaceState({}, document.title, url.toString());
}

(async () => {
  const params = new URLSearchParams(window.location.search);
  const sessionId = params.get('session_id');

  if (!sessionId) {
    console.warn('No session_id found in URL');
    return;
  }

  try {
    // Detect consent state from CookieConsent cookie (Cookiebot/CMP)
    // Adjust this logic if you use a different CMP (OneTrust, CookieYes, etc.)
    const consent = getCookie('CookieConsent');
    const analyticsConsent = consent && consent.indexOf('statistics:true') > -1;
    const marketingConsent = consent && consent.indexOf('marketing:true') > -1;

    // Build x-ga-gcs: G + analytics(1/0) + ads(1/0) + personalization(1/0)
    const gcs = 'G' + (analyticsConsent ? '1' : '0') + (marketingConsent ? '1' : '0') + (marketingConsent ? '1' : '0');

    // TODO: Update this URL to match your sGTM endpoint
    const sgtmEndpoint = 'https://yourdomain.com/your-sgtm-path/stripe-purchase';

    const res = await fetch(sgtmEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        session_id: sessionId,
        // GA4 session stitching
        ga_session_cookie: getGaSessionCookie(),
        // Browser context
        screen_resolution: window.screen.width + 'x' + window.screen.height,
        page_title: document.title,
        page_referrer: document.referrer,
        // Consent / DMA (dynamic from CMP)
        gcs: gcs,
        npa: marketingConsent ? '0' : '1',
        dma_cps: marketingConsent ? 'a' : 'denied',
        // Stape
        stape_dcid: getCookie('Stape_dcid'),
        stape: getCookie('stape'),
        // Google Analytics
        _ga: getCookie('_ga'),
        fpid: getCookie('FPID'),
        // Google Ads
        fpau: getCookie('FPAU'),
        fpgclaw: getCookie('FPGCLAW'),
        _gcl_au: getCookie('_gcl_au'),
        fpgclgb: getCookie('FPGCLGB'),
        _gcl_aw: getCookie('_gcl_aw'),
        _gcl_gb: getCookie('_gcl_gb'),
        fpgclgs: getCookie('FPGCLGS'),
        _gcl_gs: getCookie('_gcl_gs'),
        fpgsid: getCookie('FPGSID'),
        // Google DV360
        fpgcldc: getCookie('FPGCLDC'),
        _gcl_dc: getCookie('_gcl_dc'),
        // Facebook
        _fbp: getCookie('_fbp'),
        _fbc: getCookie('_fbc'),
        // TikTok
        _ttp: getCookie('_ttp'),
        ttclid: getCookie('ttclid'),
        // Snapchat
        _scclid: getCookie('_scclid'),
        _scid: getCookie('_scid'),
        // LinkedIn
        li_fat_id: getCookie('li_fat_id'),
        // Microsoft/Bing
        uet_vid: getCookie('uet_vid'),
        _uetmsclkid: getCookie('_uetmsclkid'),
        // Pinterest
        _epik: getCookie('_epik'),
        // Klaviyo
        stape_klaviyo_kx: getCookie('stape_klaviyo_kx'),
        stape_klaviyo_email: getCookie('stape_klaviyo_email'),
        // Affiliates
        awin_awc: getCookie('awin_awc'),
        rakuten_ran_mid: getCookie('rakuten_ran_mid'),
        outbrain_cid: getCookie('outbrain_cid'),
        taboola_cid: getCookie('taboola_cid'),
      })
    });

    cleanUrl();
    const data = await res.json();
    console.log('Purchase payload:', data);
  } catch (err) {
    console.error('Stripe tracking error:', err);
  }
})();
