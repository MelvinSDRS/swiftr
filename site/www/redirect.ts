/**
 * www.swiftr.dev sends every request to swiftr.dev, same path and query.
 * It is a Worker of its own so that the site stays plain files, served with no code run.
 */
export default {
  fetch(request: Request): Response {
    const url = new URL(request.url);
    url.protocol = 'https:';
    url.hostname = 'swiftr.dev';
    return Response.redirect(url.href, 301);
  },
};
