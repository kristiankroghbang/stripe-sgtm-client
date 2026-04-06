___INFO___

{
  "type": "CLIENT",
  "id": "cvt_temp_public_id",
  "version": 1,
  "securityGroups": [],
  "displayName": "Stripe Purchase Client",
  "description": "Receives Stripe session_id from a thank-you page, calls Stripe API server-side, builds a full GA4 purchase event with ecommerce, user data, and session stitching. Developed by Kristian Krogh Bang.",
  "containerContexts": [
    "SERVER"
  ]
}


___TEMPLATE_PARAMETERS___

[
  {
    "type": "TEXT",
    "name": "requestPath",
    "displayName": "Request Path",
    "simpleValueType": true,
    "defaultValue": "/stripe-purchase",
    "help": "The path this client listens on. Must match the path in your thank-you page JS snippet."
  },
  {
    "type": "TEXT",
    "name": "stripeSecretKey",
    "displayName": "Stripe Secret Key",
    "simpleValueType": true,
    "defaultValue": "",
    "help": "Your Stripe secret key (sk_live_... or sk_test_...). Never exposed client-side."
  },
  {
    "type": "TEXT",
    "name": "allowedOrigin",
    "displayName": "Allowed Origin (CORS)",
    "simpleValueType": true,
    "defaultValue": "",
    "help": "The origin of your thank-you page, e.g. https://example.com. Leave empty to allow any origin."
  },
  {
    "type": "CHECKBOX",
    "name": "logOn",
    "checkboxText": "Log to console",
    "simpleValueType": true
  }
]


___SANDBOXED_JS_FOR_SERVER___

// Stripe Purchase Client for sGTM
//
// Receives a POST from the thank-you page with Stripe session_id and browser
// cookies, calls the Stripe Checkout Sessions API server-side, and builds a
// full GA4-compatible purchase event.
//
// Included in event data:
//   - Ecommerce: items, value, tax, coupon, shipping, currency, payment_type
//   - User data: email, phone (E.164), name, address - with _tag_mode MANUAL
//   - Session stitching: client_id, ga_session_id, ga_session_number from cookies
//   - Consent: x-ga-gcs, x-ga-gcd, x-ga-dma, x-ga-npa (dynamic from CMP)
//   - Browser context: ip_override, user_agent, page_location, language
//   - Ad platform cookies: Meta, Google, TikTok, Snap, LinkedIn, Pinterest, etc.

var claimRequest = require('claimRequest');
var getRequestBody = require('getRequestBody');
var getRequestHeader = require('getRequestHeader');
var getRequestMethod = require('getRequestMethod');
var getRequestPath = require('getRequestPath');
var returnResponse = require('returnResponse');
var runContainer = require('runContainer');
var setResponseBody = require('setResponseBody');
var setResponseHeader = require('setResponseHeader');
var setResponseStatus = require('setResponseStatus');
var sendHttpRequest = require('sendHttpRequest');
var JSON = require('JSON');
var logToConsole = require('logToConsole');
var makeString = require('makeString');
var makeInteger = require('makeInteger');
var getTimestampMillis = require('getTimestampMillis');
var generateRandom = require('generateRandom');

var requestPath = data.requestPath || '/stripe-purchase';
var stripeKey = data.stripeSecretKey;
var allowedOrigin = data.allowedOrigin || '*';

// --- CORS preflight ---
if (getRequestMethod() === 'OPTIONS') {
  if (getRequestPath() === requestPath) {
    claimRequest();
    setResponseStatus(204);
    setResponseHeader('Access-Control-Allow-Origin', allowedOrigin);
    setResponseHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    setResponseHeader('Access-Control-Allow-Headers', 'Content-Type');
    setResponseHeader('Access-Control-Max-Age', '86400');
    returnResponse();
    return;
  }
  return;
}

if (getRequestMethod() !== 'POST' || getRequestPath() !== requestPath) return;

claimRequest();

// --- Parse request body ---
var rawBody = getRequestBody();
var body;
if (rawBody) {
  body = JSON.parse(rawBody);
}

if (!body || !body.session_id) {
  log('[Stripe Client] Rejected: missing session_id');
  sendError(400, 'Missing session_id');
  return;
}

if (!stripeKey) {
  log('[Stripe Client] Rejected: no Stripe key configured');
  sendError(500, 'Server misconfigured');
  return;
}

// --- Capture browser context from request headers ---
var userAgent = getRequestHeader('User-Agent') || '';
var userIp = getRequestHeader('X-Real-Ip') || getRequestHeader('cf-connecting-ip') || getRequestHeader('X-Forwarded-For') || '';
var referer = getRequestHeader('Referer') || '';
var language = getRequestHeader('Accept-Language') || '';
// Extract primary language and lowercase (e.g. "da-DK,da;q=0.9" -> "da-dk")
if (language.indexOf(',') > -1) {
  language = language.split(',')[0];
}
if (language) {
  language = language.toLowerCase();
}

var sessionId = body.session_id;
var cfCountry = getRequestHeader('cf-ipcountry') || '';
log('[Stripe Client] Processing session: ' + sessionId);

// --- Extract GA4 session stitching from cookies ---
// client_id from _ga cookie: "GA1.1.139886646.1774530580" -> "139886646.1774530580"
var clientId = undefined;
if (body._ga) {
  var gaParts = body._ga.split('.');
  if (gaParts.length >= 4) {
    clientId = gaParts[2] + '.' + gaParts[3];
  }
}
var generatedClientId = false;
if (!clientId) {
  // Generate fallback client_id
  clientId = 'generatedCid.1.' + getTimestampMillis() + '.' + generateRandom(100000000, 999999999);
  generatedClientId = true;
}

// ga_session_id and ga_session_number from _ga_XXXXXX cookie
// Format: "GS2.1.s1775413209$o6$g1$t1775422581$j60$l0$h123149623"
// session_id = number after "s", session_number = number after "o"
var gaSessionId = undefined;
var gaSessionNumber = 1;
if (body.ga_session_cookie) {
  var sessionParts = body.ga_session_cookie.split('.');
  if (sessionParts.length >= 3) {
    var segment = sessionParts[2];
    // Extract session_id (after "s", before first "$")
    if (segment.indexOf('s') === 0) {
      var dollarIndex = segment.indexOf('$');
      if (dollarIndex > 1) {
        gaSessionId = segment.substring(1, dollarIndex);
      } else {
        gaSessionId = segment.substring(1);
      }
    }
    // Extract session_number (after "$o", before next "$")
    var oIndex = segment.indexOf('$o');
    if (oIndex > -1) {
      var afterO = segment.substring(oIndex + 2);
      var nextDollar = afterO.indexOf('$');
      if (nextDollar > 0) {
        gaSessionNumber = makeInteger(afterO.substring(0, nextDollar));
      } else {
        gaSessionNumber = makeInteger(afterO);
      }
    }
  }
}
if (!gaSessionId) {
  gaSessionId = makeString(makeInteger(getTimestampMillis() / 1000));
}

// --- Call Stripe Checkout Sessions API ---
var stripeUrl = 'https://api.stripe.com/v1/checkout/sessions/' + sessionId + '?expand[]=line_items&expand[]=customer&expand[]=total_details.breakdown&expand[]=payment_intent.latest_charge';

sendHttpRequest(stripeUrl, function(statusCode, headers, responseBody) {
  if (statusCode !== 200) {
    log('[Stripe Client] Stripe API error: ' + statusCode + ' - ' + responseBody);
    sendError(502, 'Stripe API error');
    return;
  }

  var session = JSON.parse(responseBody);

  // Verify payment is completed
  if (session.payment_status !== 'paid') {
    log('[Stripe Client] Session not paid: ' + session.payment_status);
    sendError(400, 'Payment not completed');
    return;
  }

  // --- Build line items (GA4 ecommerce) ---
  var items = [];
  if (session.line_items && session.line_items.data) {
    for (var i = 0; i < session.line_items.data.length; i++) {
      var item = session.line_items.data[i];
      var itemData = {
        item_name: item.description,
        item_id: item.price ? makeString(item.price.product) : undefined,
        price: item.amount_total / 100,
        quantity: item.quantity
      };
      if (item.price) {
        itemData.item_variant = makeString(item.price.id);
      }
      items.push(itemData);
    }
  }

  // --- Extract tax ---
  var tax = 0;
  if (session.total_details && session.total_details.amount_tax) {
    tax = session.total_details.amount_tax / 100;
  }

  // --- Extract shipping ---
  var shipping = 0;
  if (session.total_details && session.total_details.amount_shipping) {
    shipping = session.total_details.amount_shipping / 100;
  }

  // --- Extract coupon/promo code ---
  var coupon = undefined;
  var discount = 0;
  if (session.total_details && session.total_details.breakdown && session.total_details.breakdown.discounts) {
    var discounts = session.total_details.breakdown.discounts;
    if (discounts.length > 0) {
      discount = session.total_details.amount_discount / 100;
      if (discounts[0].discount && discounts[0].discount.coupon) {
        coupon = discounts[0].discount.coupon.name || discounts[0].discount.coupon.id;
      }
    }
  }

  // --- Extract payment method ---
  var paymentType = session.payment_method_types ? session.payment_method_types[0] : undefined;

  // --- Extract billing details from charge (has cardholder's real name) ---
  var billing = {};
  if (session.payment_intent && typeof session.payment_intent === 'object') {
    var charge = session.payment_intent.latest_charge;
    if (charge && typeof charge === 'object' && charge.billing_details) {
      billing = charge.billing_details;
    }
  }

  // --- Resolve names from Stripe's actual field structure ---
  var customer = session.customer_details || {};
  var address = billing.address || customer.address || {};

  // Stripe stores personal name in individual_name, business in business_name
  // customer_details.name is the display name (often the business name, NOT personal)
  var fullName = customer.individual_name || billing.name || customer.name || '';
  var nameParts = fullName.split(' ');
  var firstName = nameParts[0] || undefined;
  var lastName = nameParts.length > 1 ? nameParts.slice(1).join(' ') : undefined;

  // Business name: directly from customer_details.business_name
  var businessName = customer.business_name || undefined;
  // Fallback to custom_fields
  if (!businessName && session.custom_fields) {
    for (var f = 0; f < session.custom_fields.length; f++) {
      if (session.custom_fields[f].text) {
        businessName = session.custom_fields[f].text.value;
      }
    }
  }
  // Fallback to collected_information
  if (!businessName && session.collected_information && session.collected_information.business_name) {
    businessName = session.collected_information.business_name;
  }

  // Use billing email/phone as fallback
  var email = customer.email || billing.email || undefined;
  var phone = customer.phone || billing.phone || undefined;

  // --- Build user_data (GA4 + Meta CAPI compatible) ---
  var userData = {
    _tag_mode: 'MANUAL',
    email: email,
    phone_number: phone ? formatPhone(phone, makeLower(address.country)) : undefined,
    address: [{
      first_name: makeLower(firstName),
      last_name: makeLower(lastName),
      street: makeLower(address.line1),
      city: makeLower(address.city),
      postal_code: address.postal_code,
      region: makeLower(address.state),
      country: makeLower(address.country)
    }]
  };

  // --- Extract user_id from Stripe customer ---
  var userId = undefined;
  if (session.customer && typeof session.customer === 'object') {
    userId = makeString(session.customer.id);
  } else if (session.customer) {
    userId = makeString(session.customer);
  }

  // --- Build cookie string for event data ---
  var cookieParts = [];
  var bodyToCookie = {
    'fpid': 'FPID', 'fpau': 'FPAU', 'fpgclaw': 'FPGCLAW',
    'fpgclgb': 'FPGCLGB', 'fpgclgs': 'FPGCLGS', 'fpgsid': 'FPGSID',
    'fpgcldc': 'FPGCLDC', 'stape_dcid': 'Stape_dcid'
  };
  var skipKeys = {
    'session_id': 1, 'ga_session_cookie': 1, 'screen_resolution': 1,
    'page_title': 1, 'page_referrer': 1, 'gcs': 1, 'npa': 1, 'dma_cps': 1
  };
  for (var ck in body) {
    if (body.hasOwnProperty(ck) && body[ck] && !skipKeys[ck]) {
      var cookieName = bodyToCookie[ck] || ck;
      cookieParts.push(cookieName + '=' + body[ck]);
    }
  }
  var cookieString = cookieParts.join('; ');

  // --- Build event data object ---
  var eventData = {
    // GA4 core
    event_name: 'purchase',
    client_id: clientId,
    user_id: userId,
    generated_client_id: generatedClientId,
    ga_session_id: gaSessionId,
    ga_session_number: gaSessionNumber,

    // GA4 ecommerce
    transaction_id: makeString(session.payment_intent && typeof session.payment_intent === 'object' ? session.payment_intent.id : (session.payment_intent || session.id)),
    value: session.amount_total / 100,
    currency: session.currency ? session.currency.toUpperCase() : 'DKK',
    tax: tax,
    shipping: shipping,
    coupon: coupon,
    discount: discount,
    items: items,
    payment_type: paymentType,

    // User data (GA4 + Meta CAPI)
    user_data: userData,
    customer_email: email,
    customer_name: fullName,
    customer_phone: phone,
    customer_city: address.city,
    customer_country: address.country,
    customer_business_name: businessName,

    // Browser context
    ip_override: userIp,
    user_agent: userAgent,
    page_location: referer,
    page_referrer: body.page_referrer || '',
    page_title: body.page_title || '',
    language: language,
    screen_resolution: body.screen_resolution || '',

    // GA4 protocol fields (dynamic from browser consent state)
    'x-ga-gcs': body.gcs || 'G100',
    'x-ga-gcd': buildGcd(body.gcs),
    'x-ga-protocol_version': '2',
    'x-ga-dma': cfCountry ? (isEuCountry(cfCountry) ? '1' : '0') : '1',
    'x-ga-dma_cps': body.dma_cps || 'a',
    'x-ga-npa': body.npa || '0',
    engagement_time_msec: 1,

    // Cookie string
    cookies: cookieString,

    // Stripe metadata
    'x-stripe-session-id': sessionId,
    'x-stripe-payment-intent': session.payment_intent && typeof session.payment_intent === 'object' ? session.payment_intent.id : session.payment_intent,
    source: 'stripe_checkout'
  };

  // --- Merge all ad platform cookies into eventData ---
  mergeIfSet(eventData, 'stape_dcid', body.stape_dcid);
  mergeIfSet(eventData, 'stape', body.stape);
  mergeIfSet(eventData, '_ga', body._ga);
  mergeIfSet(eventData, 'fpid', body.fpid);
  mergeIfSet(eventData, 'fpau', body.fpau);
  mergeIfSet(eventData, 'fpgclaw', body.fpgclaw);
  mergeIfSet(eventData, '_gcl_au', body._gcl_au);
  mergeIfSet(eventData, 'fpgclgb', body.fpgclgb);
  mergeIfSet(eventData, '_gcl_aw', body._gcl_aw);
  mergeIfSet(eventData, '_gcl_gb', body._gcl_gb);
  mergeIfSet(eventData, 'fpgclgs', body.fpgclgs);
  mergeIfSet(eventData, '_gcl_gs', body._gcl_gs);
  mergeIfSet(eventData, 'fpgsid', body.fpgsid);
  mergeIfSet(eventData, 'fpgcldc', body.fpgcldc);
  mergeIfSet(eventData, '_gcl_dc', body._gcl_dc);
  mergeIfSet(eventData, '_fbp', body._fbp);
  mergeIfSet(eventData, '_fbc', body._fbc);
  mergeIfSet(eventData, '_ttp', body._ttp);
  mergeIfSet(eventData, 'ttclid', body.ttclid);
  mergeIfSet(eventData, '_scclid', body._scclid);
  mergeIfSet(eventData, '_scid', body._scid);
  mergeIfSet(eventData, 'li_fat_id', body.li_fat_id);
  mergeIfSet(eventData, 'uet_vid', body.uet_vid);
  mergeIfSet(eventData, '_uetmsclkid', body._uetmsclkid);
  mergeIfSet(eventData, '_epik', body._epik);
  mergeIfSet(eventData, 'stape_klaviyo_kx', body.stape_klaviyo_kx);
  mergeIfSet(eventData, 'stape_klaviyo_email', body.stape_klaviyo_email);
  mergeIfSet(eventData, 'awin_awc', body.awin_awc);
  mergeIfSet(eventData, 'rakuten_ran_mid', body.rakuten_ran_mid);
  mergeIfSet(eventData, 'outbrain_cid', body.outbrain_cid);
  mergeIfSet(eventData, 'taboola_cid', body.taboola_cid);

  fireContainer(eventData);
}, {
  method: 'GET',
  headers: {
    'Authorization': 'Bearer ' + stripeKey
  }
});


// --- Fire container and send response ---
function fireContainer(ed) {
  log('[Stripe Client] Purchase: ' + ed.transaction_id + ' | ' + ed.value + ' ' + ed.currency + ' | client_id: ' + ed.client_id);

  runContainer(ed, function() {
    setResponseStatus(200);
    setResponseHeader('Content-Type', 'application/json');
    setResponseHeader('Access-Control-Allow-Origin', allowedOrigin);
    setResponseBody(JSON.stringify({
      status: 'ok',
      transaction_id: ed.transaction_id,
      value: ed.value,
      currency: ed.currency
    }));
    returnResponse();
  });
}

// --- Utility: merge value into object only if truthy ---
function mergeIfSet(obj, key, val) {
  if (val) {
    obj[key] = val;
  }
}

// --- Utility: send error response ---
function sendError(status, message) {
  setResponseStatus(status);
  setResponseHeader('Content-Type', 'application/json');
  setResponseHeader('Access-Control-Allow-Origin', allowedOrigin);
  setResponseBody(JSON.stringify({error: message}));
  returnResponse();
}

// --- Utility: lowercase helper ---
function makeLower(val) {
  return val ? val.toLowerCase() : undefined;
}

// --- Utility: phone number formatter (E.164) ---
function formatPhone(phoneNum, countryCode) {
  if (!phoneNum || phoneNum === 'undefined') return undefined;

  var phone = makeString(phoneNum);
  if (typeof phone !== 'string') return undefined;
  phone = phone.split(' ').join('');

  // Country code to area code mapping
  var areaCodes = {
    'eg': '20', 'za': '27', 'gr': '30', 'nl': '31', 'be': '32', 'fr': '33',
    'es': '34', 'hu': '36', 'it': '39', 'ro': '40', 'ch': '41', 'at': '43',
    'gb': '44', 'dk': '45', 'se': '46', 'no': '47', 'pl': '48', 'de': '49',
    'pe': '51', 'mx': '52', 'cu': '53', 'ar': '54', 'br': '55', 'cl': '56',
    'co': '57', 'my': '60', 'au': '61', 'id': '62', 'ph': '63', 'nz': '64',
    'sg': '65', 'th': '66', 'jp': '81', 'cn': '86', 'in': '91', 'pk': '92',
    'af': '93', 'lk': '94', 'mm': '95', 'ss': '211', 'ma': '212', 'dz': '213',
    'tn': '216', 'ly': '218', 'gm': '220', 'sn': '221', 'mr': '222', 'ml': '223',
    'gn': '224', 'bf': '226', 'ne': '227', 'tg': '228', 'bj': '229', 'mu': '230',
    'lr': '231', 'sl': '232', 'gh': '233', 'ng': '234', 'td': '235', 'cf': '236',
    'cm': '237', 'gq': '240', 'ga': '241', 'cg': '242', 'cd': '243', 'ao': '244',
    'gw': '245', 'sc': '248', 'sd': '249', 'rw': '250', 'et': '251', 'so': '252',
    'dj': '253', 'ke': '254', 'ug': '256', 'bi': '257', 'mz': '258', 'zm': '260',
    'mg': '261', 're': '262', 'zw': '263', 'na': '264', 'mw': '265', 'ls': '266',
    'bw': '267', 'sz': '268', 'km': '269', 'er': '291', 'aw': '297', 'fo': '298',
    'gl': '299', 'gi': '350', 'pt': '351', 'lu': '352', 'ie': '353', 'is': '354',
    'al': '355', 'mt': '356', 'cy': '357', 'fi': '358', 'bg': '359', 'lt': '370',
    'lv': '371', 'ee': '372', 'am': '374', 'by': '375', 'ad': '376', 'mc': '377',
    'sm': '378', 'ua': '380', 'rs': '381', 'me': '382', 'hr': '385', 'si': '386',
    'ba': '387', 'mk': '389', 'cz': '420', 'sk': '421', 'li': '423', 'us': '1',
    'ca': '1', 'gs': '500', 'bz': '501', 'gt': '502', 'sv': '503', 'hn': '504',
    'ni': '505', 'cr': '506', 'pa': '507', 'pm': '508', 'ht': '509', 'gp': '590',
    'bl': '590', 'gy': '592', 'ec': '593', 'gf': '594', 'py': '595', 'mq': '596',
    'sr': '597', 'uy': '598', 'bn': '673', 'nr': '674', 'pg': '675', 'to': '676',
    'sb': '677', 'vu': '678', 'fj': '679', 'pw': '680', 'wf': '681', 'ck': '682',
    'nu': '683', 'ws': '685', 'ki': '686', 'nc': '687', 'tv': '688', 'pf': '689',
    'tk': '690', 'mh': '692', 'hk': '852',
    'kh': '855', 'bd': '880', 'mv': '960', 'lb': '961', 'jo': '962', 'iq': '964',
    'kw': '965', 'sa': '966', 'ye': '967', 'om': '968', 'ps': '970', 'ae': '971',
    'il': '972', 'bh': '973', 'qa': '974', 'bt': '975', 'mn': '976', 'np': '977',
    'tj': '992', 'tm': '993', 'az': '994', 'ge': '995', 'kg': '996', 'uz': '998'
  };

  var areaCode = areaCodes[countryCode];
  if (!areaCode) return phone;

  if (phone.indexOf('+' + areaCode) === 0) {
    phone = phone.substring(areaCode.length + 1);
  } else if (phone.indexOf('00' + areaCode) === 0) {
    phone = phone.substring(areaCode.length + 2);
  }

  return '+' + areaCode + phone;
}

// --- Utility: build x-ga-gcd from consent state ---
// Maps consent string (e.g. "G111") to gcd format
// "l" = consent granted, "q" = consent denied
function buildGcd(gcs) {
  if (!gcs || gcs.length < 4) return '13q3q3q2q5';
  var analytics = gcs.charAt(1) === '1' ? 'l' : 'q';
  var ads = gcs.charAt(2) === '1' ? 'l' : 'q';
  var personalization = gcs.charAt(3) === '1' ? 'l' : 'q';
  return '13' + analytics + '3' + ads + '3' + personalization + '2' + ads + '5';
}

// --- Utility: check if country is in EU/EEA (DMA applies) ---
function isEuCountry(countryCode) {
  var euCountries = 'AT,BE,BG,HR,CY,CZ,DK,EE,FI,FR,DE,GR,HU,IE,IT,LV,LT,LU,MT,NL,PL,PT,RO,SK,SI,ES,SE,IS,LI,NO';
  return euCountries.indexOf(countryCode) > -1;
}

// --- Utility: conditional logging ---
function log(msg) {
  if (data.logOn) {
    logToConsole(msg);
  }
}


___SERVER_PERMISSIONS___

[
  {
    "instance": {
      "key": {
        "publicId": "read_request",
        "versionId": "1"
      },
      "param": [
        {
          "key": "requestAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "headerAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "bodyAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "pathAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "queryParameterAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        }
      ]
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "access_response",
        "versionId": "1"
      },
      "param": [
        {
          "key": "writeResponseAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "writeHeaderAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "writeStatusAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        },
        {
          "key": "writeBodyAccess",
          "value": {
            "type": 1,
            "string": "any"
          }
        }
      ]
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "return_response",
        "versionId": "1"
      }
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "run_container",
        "versionId": "1"
      }
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "send_http",
        "versionId": "1"
      },
      "param": [
        {
          "key": "allowedUrls",
          "value": {
            "type": 1,
            "string": "specific"
          }
        },
        {
          "key": "urls",
          "value": {
            "type": 2,
            "listItem": [
              {
                "type": 1,
                "string": "https://api.stripe.com/*"
              }
            ]
          }
        }
      ]
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "logging",
        "versionId": "1"
      },
      "param": [
        {
          "key": "environments",
          "value": {
            "type": 1,
            "string": "debug"
          }
        }
      ]
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  }
]


___TESTS___

scenarios: []
