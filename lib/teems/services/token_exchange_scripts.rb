# frozen_string_literal: true

module Teems
  module Services
    # JavaScript and text constants for token exchange and manual instructions.
    # Separated from TokenExtractorScripts to keep modules under line limits.
    module TokenExchangeScripts
      # JavaScript to exchange skype spaces token for skypeToken via authsvc
      EXCHANGE_TOKEN_JS = <<~JS
        (function(skypeSpacesToken) {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', 'https://teams.microsoft.com/api/authsvc/v1.0/authz', false);
          xhr.setRequestHeader('Authorization', 'Bearer ' + skypeSpacesToken);
          xhr.setRequestHeader('Content-Type', 'application/json');
          try {
            xhr.send('{}');
            if (xhr.status === 200) {
              var result = JSON.parse(xhr.responseText);
              return JSON.stringify({
                skype_token: result.tokens.skypeToken,
                region: result.region,
                chat_service: result.regionGtms.chatService
              });
            }
          } catch(e) {}
          return JSON.stringify({error: 'Exchange failed'});
        })(%s)
      JS

      MANUAL_TOKEN_INSTRUCTIONS = <<~INSTRUCTIONS
        To manually extract tokens:

        1. Open https://teams.microsoft.com in your browser
        2. Log in with your credentials (PIV/Entra ID)
        3. Open Developer Tools (F12 or Cmd+Option+I)
        4. Go to Console tab and run:

           // Get Graph token (for teams/channels)
           for (let i = 0; i < localStorage.length; i++) {
             let key = localStorage.key(i);
             if (key.includes('accesstoken') && key.includes('graph.microsoft.com')) {
               console.log('auth_token:', JSON.parse(localStorage.getItem(key)).secret);
             }
           }

        5. To get the skypeToken (for messages), you need to:
           a. Find the api.spaces.skype.com token in localStorage
           b. Exchange it via POST to /api/authsvc/v1.0/authz
           c. Or capture it from Network tab (Authentication header)

        The skypeToken uses format: Authentication: skypetoken=<token>
        The Graph token uses format: Authorization: Bearer <token>
      INSTRUCTIONS
    end
  end
end
