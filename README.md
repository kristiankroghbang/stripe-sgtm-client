# Stripe Checkout - sGTM Client

Server-side Google Tag Manager client template for tracking [Stripe Checkout](https://stripe.com/docs/payments/checkout) purchases. Calls the Stripe API server-side and builds a full GA4-compatible purchase event with ecommerce data, user data, session stitching, and 30+ ad platform cookies.

Developed by [Kristian Krogh Bang](https://kristiankroghbang.com) and [Claude 4.6](https://claude.ai).

## The problem

Stripe Checkout (including Payment Links) redirects customers to a Stripe-hosted payment page. Since the checkout happens on Stripe's domain, your tracking pixels and server-side tags never see the purchase event. The thank-you page knows the customer bought something, but has no order details - no revenue, no items, no customer data.

Most workarounds either expose your Stripe secret key client-side (security risk) or require a custom backend just to proxy the API call.

## The solution

A lightweight JS snippet on your thank-you page sends the Stripe session ID and browser cookies to your sGTM container. The sGTM client template calls the Stripe API server-side (your secret key never leaves the server), enriches the event with full ecommerce and customer data, and fires all your tags.

```
Stripe Checkout --> Thank-you page (JS snippet) --> sGTM Client --> Stripe API
                                                                        |
                                                                        v
                                                    GA4 / Meta CAPI / TikTok / etc.
```

No extra backend. No exposed keys. One client template + one JS snippet.

## What's included

| File | Description |
|------|-------------|
| `template.tpl` | sGTM client template - import into GTM Server Container |
| `snippet.js` | JS snippet - add to your thank-you page |
| `metadata.yaml` | GTM Community Template Gallery metadata |

## Event data

The client builds a complete GA4 `purchase` event with:

**Ecommerce:**
- `transaction_id` - Stripe payment intent ID
- `value` - Total amount (converted from cents)
- `currency` - Uppercase currency code
- `tax` - Tax amount from Stripe Tax
- `shipping` - Shipping amount
- `coupon` - Promotion code name/ID
- `discount` - Discount amount
- `payment_type` - Payment method (card, klarna, link, etc.)
- `items[]` - Line items with `item_name`, `item_id`, `price`, `quantity`, `item_variant`

**User data (GA4 + Meta CAPI compatible):**
- `user_data.email` - Customer email
- `user_data.phone_number` - Phone in E.164 format (200+ country codes)
- `user_data.address[]` - First name, last name, street, city, postal code, region, country
- `_tag_mode: "MANUAL"` - Ensures Meta CAPI uses the provided user data
- `user_id` - Stripe customer ID (when available)
- `customer_business_name` - Business name (from `customer_details.business_name`)

**Name resolution:**

Stripe stores personal and business names separately. The template uses `customer_details.individual_name` (the personal name) for `first_name`/`last_name`, and `customer_details.business_name` for the business name. It falls back to `billing_details.name` (the cardholder name from the payment) if `individual_name` is not available.

**Session stitching:**
- `client_id` - Extracted from `_ga` cookie (falls back to generated ID)
- `ga_session_id` - Extracted from `_ga_XXXXXX` cookie
- `ga_session_number` - Extracted from `_ga_XXXXXX` cookie
- `ip_override` - Real user IP from request headers
- `user_agent` - Real browser User-Agent
- `page_location` - Thank-you page URL (from Referer header)
- `page_referrer` - Previous page (from JS snippet)
- `page_title` - Page title (from JS snippet)
- `screen_resolution` - Screen dimensions (from JS snippet)
- `language` - Browser language (from Accept-Language header)

**Consent and DMA:**
- `x-ga-gcs` - Google Consent State (dynamic from CMP cookie)
- `x-ga-gcd` - Google Consent Default (derived from consent state)
- `x-ga-dma` - Digital Markets Act flag (dynamic from `cf-ipcountry` header)
- `x-ga-dma_cps` - DMA consent parameter
- `x-ga-npa` - No personalized ads signal

**Ad platform cookies (30+):**

| Platform | Cookies |
|----------|---------|
| Google Analytics | `_ga`, `FPID` |
| Google Ads | `FPAU`, `FPGCLAW`, `_gcl_au`, `_gcl_aw`, `_gcl_gb`, `_gcl_gs`, `FPGSID` |
| Google DV360 | `FPGCLDC`, `_gcl_dc` |
| Meta (Facebook) | `_fbp`, `_fbc` |
| TikTok | `_ttp`, `ttclid` |
| Snapchat | `_scclid`, `_scid` |
| LinkedIn | `li_fat_id` |
| Microsoft/Bing | `uet_vid`, `_uetmsclkid` |
| Pinterest | `_epik` |
| Klaviyo | `stape_klaviyo_kx`, `stape_klaviyo_email` |
| Affiliates | `awin_awc`, `rakuten_ran_mid`, `outbrain_cid`, `taboola_cid` |

Cookies are included both as individual event data fields and as a combined `cookies` string.

## Setup

### 1. Configure Stripe Payment Link

In Stripe Dashboard, edit your Payment Link:

1. Go to **Payment Links** and select your link
2. Click **After payment** tab
3. Select **"Don't show confirmation page"**
4. Set the redirect URL to your thank-you page with the session ID parameter:

```
https://yourdomain.com/thank-you?session_id={CHECKOUT_SESSION_ID}
```

Stripe automatically replaces `{CHECKOUT_SESSION_ID}` with the real session ID at checkout time.

**For custom Stripe integrations** (not Payment Links), add the same parameter to your `success_url` when creating a Checkout Session:

```javascript
const session = await stripe.checkout.sessions.create({
  // ...
  success_url: 'https://yourdomain.com/thank-you?session_id={CHECKOUT_SESSION_ID}',
});
```

### 2. Add the JS snippet to your thank-you page

Copy `snippet.js` into a `<script>` tag before `</body>` on your thank-you page.

**You must update two things in the snippet:**

**a) The sGTM endpoint URL** (line 57):

```javascript
const sgtmEndpoint = 'https://yourdomain.com/your-sgtm-path/stripe-purchase';
```

Replace with your actual sGTM container URL. For example, if your sGTM runs at `https://sst.example.com` with a custom proxy path `/metrics`, the URL would be `https://example.com/metrics/stripe-purchase`.

**b) The consent detection** (lines 47-54):

The snippet reads consent state from a `CookieConsent` cookie in [Cookiebot](https://www.cookiebot.com/) format. If you use a different CMP, update the consent detection:

```javascript
// Cookiebot (default)
const consent = getCookie('CookieConsent');
const analyticsConsent = consent && consent.indexOf('statistics:true') > -1;
const marketingConsent = consent && consent.indexOf('marketing:true') > -1;

// OneTrust - replace with:
// const consent = getCookie('OptanonConsent');
// const analyticsConsent = consent && consent.indexOf('C0002:1') > -1;
// const marketingConsent = consent && consent.indexOf('C0004:1') > -1;

// No CMP - grant all:
// const analyticsConsent = true;
// const marketingConsent = true;
```

### 3. Import the sGTM client template

1. In your GTM Server Container, go to **Templates** > **Client Templates** > **New**
2. Click the three-dot menu > **Import** > upload `template.tpl`
3. Save the template
4. Go to **Clients** > **New** > select **Stripe Purchase Client**
5. Configure the fields:

| Field | Value |
|-------|-------|
| **Request Path** | The path your snippet POSTs to (default: `/stripe-purchase`). Must match the last segment of your sGTM endpoint URL. |
| **Stripe Secret Key** | Your `sk_live_...` or `sk_test_...` key. This is stored server-side in sGTM and never exposed to the browser. |
| **Allowed Origin (CORS)** | The origin of your thank-you page, e.g. `https://yourdomain.com`. Prevents other domains from calling your endpoint. Leave empty to allow any origin (not recommended for production). |
| **Log to console** | Check this during setup to see debug output in sGTM Preview mode. Uncheck for production. |

6. Save the client and publish the container

### 4. Create tags in sGTM

All fields are available as **Event Data** variables in your sGTM tags:

- `{{Event Data - event_name}}` - Always `purchase`
- `{{Event Data - transaction_id}}` - Stripe payment intent ID
- `{{Event Data - value}}` - Order total
- `{{Event Data - currency}}` - Currency code
- `{{Event Data - items}}` - Line items array
- `{{Event Data - user_data}}` - Full user data object
- `{{Event Data - client_id}}` - GA4 client ID for session stitching
- `{{Event Data - customer_email}}` - Customer email (direct access)
- `{{Event Data - customer_business_name}}` - Business name
- `{{Event Data - cookies}}` - Full cookie string

### 5. Test

1. Publish your sGTM container
2. Open sGTM Preview mode
3. Complete a purchase via your Payment Link using test card `4242 4242 4242 4242` (any future expiry, any CVC)
4. You should be redirected to your thank-you page
5. In sGTM Preview, verify the purchase event appears with full ecommerce data, user data, and cookies

## How it works

1. Customer completes Stripe Checkout and is redirected to your thank-you page with `?session_id=cs_live_...`
2. The JS snippet reads the session ID from the URL, collects all browser cookies and context, and POSTs to your sGTM endpoint
3. The sGTM client claims the request and calls `GET /v1/checkout/sessions/{id}` on the Stripe API with your secret key (server-to-server, never exposed)
4. Stripe returns the full session object with customer details, line items, tax, discounts, and payment status
5. The client verifies `payment_status === 'paid'`, builds a GA4-compatible event, and runs the container
6. All your sGTM tags (GA4, Meta CAPI, TikTok, etc.) fire with the enriched data
7. The snippet removes `session_id` from the URL so the page shows a clean URL and prevents duplicate tracking on refresh

## Security

- **Stripe secret key** lives only in your sGTM container (server-side). It is never sent to the browser or included in any client-side code.
- **Payment validation** - The client verifies `payment_status === 'paid'` before firing any tags. Unpaid or incomplete sessions are rejected with a 400 response.
- **CORS** - Configurable allowed origin prevents other domains from hitting your endpoint.
- **No client-side API calls** - The browser only sends the session ID and cookies. All Stripe API communication happens server-to-server.

## Comparison with other approaches

| Approach | Stripe key exposed? | Extra infrastructure? | Session stitching? | Full ecom data? |
|----------|--------------------|-----------------------|-------------------|----------------|
| **This template** | No | No | Yes | Yes |
| Client-side Stripe.js | Yes (publishable) | No | Yes | Limited |
| Custom backend proxy | No | Yes (Node.js/Python) | No | Yes |
| Stripe webhooks | No | Yes (webhook handler) | No | Yes |
| Zapier/Make | No | Yes (third-party) | No | Partial |

## Limitations

- **Payment Links and Checkout only** - Designed for Stripe Checkout / Payment Links with redirect. For custom Stripe integrations, add `?session_id={CHECKOUT_SESSION_ID}` to your `success_url` when creating a Checkout Session.
- **Deduplication on refresh** - The snippet removes `session_id` from the URL after firing, so a page refresh will not trigger a duplicate event. However, if the user navigates back to the thank-you page via browser history with the original URL, the event could fire again. Use `transaction_id` for deduplication in your tags as a safety net.
- **Cookie availability** - Cookies must be set on the same domain as the thank-you page. If your thank-you page is on a different domain than where the cookies were set, they won't be available.
- **CMP integration** - The snippet includes consent detection for Cookiebot by default. If you use a different CMP (OneTrust, CookieYes, etc.), you need to update the consent logic in `snippet.js`.

## Resources

- [Stripe Checkout Sessions API](https://docs.stripe.com/api/checkout/sessions)
- [Stripe Payment Links](https://docs.stripe.com/payment-links)
- [sGTM Client Templates Guide](https://developers.google.com/tag-platform/tag-manager/server-side/api)

## License

Apache 2.0 - see [LICENSE](LICENSE).
