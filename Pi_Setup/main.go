package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	lksdk "github.com/livekit/server-sdk-go/v2"
)

const (
	BACKEND_IP = "192.168.1.15" // CHANGE THIS TO YOUR BACKEND LAPTOP IP
	DEVICE_ID  = "pi-patient-02"
)

type tokenResponse struct {
	Token string `json:"token"`
	Room  string `json:"room"`
}

func main() {
	for {
		token, roomName, err := fetchToken(BACKEND_IP, DEVICE_ID)
		if err != nil {
			log.Printf("token fetch failed: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		log.Printf("connecting to LiveKit room: %s", roomName)
		room, err := lksdk.ConnectToRoom(
			"ws://"+BACKEND_IP+":7880",
			lksdk.ConnectInfo{
				APIKey: "devkey",
				Token:  token,
			},
		)
		if err != nil {
			log.Printf("connect failed: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		<-room.DisconnectedNotify()
		log.Printf("disconnected from LiveKit; retrying in 5 seconds")
		time.Sleep(5 * time.Second)
	}
}

func fetchToken(backendIP, deviceID string) (string, string, error) {
	url := "http://" + backendIP + ":5000/api/edge/token?deviceId=" + deviceID
	resp, err := http.Get(url)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("token endpoint returned %s", resp.Status)
	}

	var payload tokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", "", err
	}
	if payload.Token == "" {
		return "", "", fmt.Errorf("empty token in response")
	}

	return payload.Token, payload.Room, nil
}
 
