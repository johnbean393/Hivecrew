//
//  IPLocation.swift
//  Hivecrew
//
//  IP-based geolocation service using ipapi.co
//

import Foundation

public class IPLocation {
    
    /// Get the user's current location based on IP address
    /// Returns a formatted string like "San Francisco, California, US"
    static func getLocation() async throws -> String {
        // Hit API
        let url = URL(string: "https://ipapi.co/json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(IPLocationResponse.self, from: data)
        // Join strings
        var locationComponents: [String] = []
        if let city = response.city {
            locationComponents.append(city)
        }
        if let region = response.region {
            locationComponents.append(region)
        }
        if let country = response.country {
            locationComponents.append(country)
        }
        return locationComponents.joined(separator: ", ")
    }
    
}

public struct IPLocationResponse: Codable {
    
    let city: String?
    let region: String?
    let country: String?
    
}
