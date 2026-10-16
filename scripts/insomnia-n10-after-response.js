// Insomnia after-response script — pulls access_token out of the response
// body and stores it as an environment variable, so later requests can
// reference it as {{ _.access_token }}.
//
// Paste into a request/folder/collection's "Scripts > After-Response Script" tab.

if (insomnia.response.status >= 200 && insomnia.response.status < 300) {
    const body = insomnia.response.json();
    if (body && body.access_token) {
        insomnia.environment.set('access_token', body.access_token);
    }
}
