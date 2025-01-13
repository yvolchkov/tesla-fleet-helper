package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/google/uuid"
)

// energy_device_data, energy_cmds are left out for now
const ApiScope = "openid offline_access user_data vehicle_device_data vehicle_location vehicle_cmds vehicle_charging_cmds"

// Config holds the Tesla OAuth credentials read from config.json.
type Config struct {
	TeslaClientID     string `json:"client_id"`
	TeslaClientSecret string `json:"client_secret"`
	TeslaRedirectURI  string `json:"redirect_uri"`
	TeslaAudience     string `json:"audience"`
	Domain            string `json:"fleet_domain"`
}

// TokenResponse represents the response from Tesla’s token endpoint.
type TokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	IDToken      string `json:"id_token,omitempty"`
	// ... other fields as needed
}

type PartnerTokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
	TokenType   string `json:"token_type"`
}

var (
	// We'll load this once in main()
	config Config

	// Simple in-memory storage for demonstration
	userTokens = map[string]TokenResponse{}
)

type TeslaSecrets struct {
	PartnerToken string `json:"partner_token"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

func (secrets *TeslaSecrets) getPartnerToken() error {

	if secrets.PartnerToken != "" {
		log.Printf("Using existing partner token: %s", secrets.PartnerToken)
		return nil
	}

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", config.TeslaClientID)
	form.Set("client_secret", config.TeslaClientSecret)
	form.Set("audience", config.TeslaAudience)
	form.Set("scope", ApiScope)

	req, err := http.NewRequest("POST", "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token", bytes.NewBufferString(form.Encode()))
	if err != nil {
		return fmt.Errorf("could not create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("could not send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("non-200 response from token endpoint: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("could not read response body: %w", err)
	}

	var tokenResp PartnerTokenResponse
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return fmt.Errorf("could not unmarshal response JSON: %w", err)
	}

	log.Printf("Partner app registered successfully: %s", tokenResp.AccessToken)
	secrets.PartnerToken = tokenResp.AccessToken
	return nil
}

func (secrets *TeslaSecrets) load_secrets() error {
	if _, err := os.Stat("secrets.json"); errors.Is(err, os.ErrNotExist) {
		return nil
	}

	file, err := os.Open("secrets.json")
	if err != nil {
		return fmt.Errorf("could not open secrets file: %w", err)
	}

	decoder := json.NewDecoder(file)
	if err := decoder.Decode(secrets); err != nil {
		return fmt.Errorf("could not decode secrets JSON: %w", err)
	}
	return nil
}

func (secrets *TeslaSecrets) save_secrets() error {
	file, err := os.Create("secrets.json")
	if err != nil {
		return fmt.Errorf("could not create secrets file: %w", err)
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	if err := encoder.Encode(secrets); err != nil {
		return fmt.Errorf("could not encode secrets JSON: %w", err)
	}
	return nil
}

func (secrets *TeslaSecrets) registerParnerApp() error {
	payload := map[string]string{
		"domain": config.Domain,
	}
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("could not marshal JSON: %w", err)
	}

	url := fmt.Sprintf("%s/api/1/partner_accounts", config.TeslaAudience)
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("could not create request: %w", err)
	}

	log.Printf("url is %s", url)

	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", secrets.PartnerToken))
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("could not send request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("could not read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("non-200 response from token endpoint: %d\n%s", resp.StatusCode, body)
	}

	var prettyJSON bytes.Buffer
	err = json.Indent(&prettyJSON, body, "", "  ")
	if err != nil {
		return fmt.Errorf("could not indent JSON: %w", err)
	}

	log.Printf("Partner app registered successfully: %v\n", prettyJSON.String())
	return nil
}

func main() {
	// 1) Load configuration from JSON file
	err := loadConfig("config.json", &config)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	var secrets TeslaSecrets
	defer secrets.save_secrets()

	if err := secrets.load_secrets(); err != nil {
		log.Fatalf("Failed to load secrets: %v", err)
	}

	log.Printf("client_id: %s", config.TeslaClientID)
	log.Println("client_secret: %s", config.TeslaClientSecret)
	// 2) Set up HTTP handlers
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/login", handleLogin)

	done := make(chan struct{})

	http.HandleFunc("/tesla/auth/callback", func(w http.ResponseWriter, r *http.Request) {
		secrets.handleCallback(w, r, done)
	})

	http.HandleFunc("/.well-known/appspecific/com.tesla.3p.public-key.pem", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "public-key.pem")
	})

	// 3) Start the HTTP server
	log.Println("Starting server on :8934")
	go func() {
		log.Fatal(http.ListenAndServe(":8934", nil))
	}()

	time.Sleep(1 * time.Second)
	err = secrets.getPartnerToken()
	if err != nil {
		log.Fatalf("Failed to get partner token: %v", err)
	}

	log.Println("------")
	if err := secrets.registerParnerApp(); err != nil {
		log.Fatalf("Failed to register partner app: %v", err)
	}

	<-done
	secrets.save_secrets()

	log.Println("Done!, press Ctrl+C to exit")
	select {}
}

// loadConfig reads the given JSON config file into the config struct.
func loadConfig(filename string, conf *Config) error {
	file, err := os.Open(filename)
	if err != nil {
		return fmt.Errorf("could not open config file: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	if err = decoder.Decode(conf); err != nil {
		return fmt.Errorf("could not decode config JSON: %w", err)
	}
	return nil
}

// handleIndex displays a simple landing page with a login link.
func handleIndex(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "<html><body>")
	fmt.Fprintln(w, `<h1>Welcome</h1>`)
	fmt.Fprintln(w, `<p><a href="/login">Login with Tesla</a></p>`)
	fmt.Fprintln(w, "</body></html>")
}

// handleLogin redirects the user to Tesla's /authorize endpoint.
func handleLogin(w http.ResponseWriter, r *http.Request) {
	// Generate a random state to protect against CSRF
	state := uuid.NewString()

	// Build the /authorize URL
	authorizeURL, _ := url.Parse("https://auth.tesla.com/oauth2/v3/authorize")
	// Construct query parameters
	query := authorizeURL.Query()
	query.Set("response_type", "code")
	query.Set("client_id", config.TeslaClientID)
	query.Set("redirect_uri", config.TeslaRedirectURI)
	query.Set("scope", ApiScope)
	query.Set("state", state)

	authorizeURL.RawQuery = query.Encode()

	log.Println("Redirecting to:", authorizeURL.String())
	// In production, store the state somewhere (session/cookie) and verify it in callback
	http.Redirect(w, r, authorizeURL.String(), http.StatusFound)
}

// handleCallback handles the redirect from Tesla’s OAuth flow.
func (secrets *TeslaSecrets) handleCallback(w http.ResponseWriter, r *http.Request, done chan<- struct{}) {
	// Typically, you'd verify the state here as well.
	code := r.URL.Query().Get("code")
	if code == "" {
		http.Error(w, "Missing code in callback URL", http.StatusBadRequest)
		return
	}

	// Exchange the code for an Access Token & Refresh Token
	tokenResp, err := exchangeCodeForToken(code)
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to get token: %v", err), http.StatusInternalServerError)
		return
	}

	// In a real app, you might map these tokens to the logged-in user’s ID.
	userID := uuid.NewString()
	userTokens[userID] = tokenResp

	fmt.Fprintf(w, "<html><body>")
	fmt.Fprintf(w, "<h2>Successfully retrieved tokens!</h2>")
	fmt.Fprintf(w, "Access Token: %s<br/>", tokenResp.AccessToken)
	fmt.Fprintf(w, "Refresh Token: %s<br/>", tokenResp.RefreshToken)
	fmt.Fprintf(w, "Token Type: %s<br/>", tokenResp.TokenType)
	fmt.Fprintf(w, "Expires In: %d<br/>", tokenResp.ExpiresIn)
	fmt.Fprintf(w, "ID Token: %s<br/>", tokenResp.IDToken)
	fmt.Fprintf(w, "</body></html>")

	secrets.AccessToken = tokenResp.AccessToken
	secrets.RefreshToken = tokenResp.RefreshToken

	done <- struct{}{}
}

// exchangeCodeForToken exchanges the authorization code for an access/refresh token.
func exchangeCodeForToken(code string) (TokenResponse, error) {
	tokenURL := "https://auth.tesla.com/oauth2/v3/token"

	body := map[string]string{
		"grant_type":    "authorization_code",
		"client_id":     config.TeslaClientID,
		"client_secret": config.TeslaClientSecret,
		"code":          code,
		"audience":      config.TeslaAudience,
		"redirect_uri":  config.TeslaRedirectURI,
		"scope":         ApiScope,
	}

	jsonBody, err := json.Marshal(body)
	if err != nil {
		return TokenResponse{}, err
	}

	req, err := http.NewRequest("POST", tokenURL, bytes.NewBuffer(jsonBody))
	if err != nil {
		return TokenResponse{}, err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return TokenResponse{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Attempt to parse any error message
		errMsg := fmt.Sprintf("Non-200 response from token endpoint: %d", resp.StatusCode)
		return TokenResponse{}, fmt.Errorf(errMsg)
	}

	var tokenResp TokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return TokenResponse{}, err
	}

	return tokenResp, nil
}
