import SwiftUI
import CoreData

import Foundation
import CoreData
import Combine

class GameState: ObservableObject {
    // Game state properties
    @Published var currentGame: GameModel?
    @Published var savedGame: GameModel?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showWinMessage = false
    @Published var showLoseMessage = false
    @Published var showContinueGameModal = false
    @Published var isInfiniteMode = false
    
    // Game metadata
    @Published var quoteAuthor: String = ""
    @Published var quoteAttribution: String? = nil
    @Published var quoteDate: String? = nil
    
    // Configuration
    @Published var isDailyChallenge = false
    @Published var defaultDifficulty = "medium"
    
    // Private properties
    private var dailyQuote: DailyQuoteModel?
    private let authCoordinator = UserState.shared.authCoordinator
    
    // Core Data access
    private let coreData = CoreDataStack.shared
    
    // Singleton instance
    static let shared = GameState()
    
    private init() {
        setupDefaultGame()
    }
    
    /// Get max mistakes based on difficulty settings
    private func getMaxMistakesForDifficulty(_ difficulty: String) -> Int {
        switch difficulty.lowercased() {
        case "easy": return 8
        case "hard": return 3
        default: return 5  // Medium difficulty
        }
    }
    
    private func setupDefaultGame() {
        // Create a placeholder game with default quote
        let defaultQuote = QuoteModel(
            text: "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG",
            author: "Anonymous",
            attribution: nil,
            difficulty: 2.0
        )
        
        var game = GameModel(quote: defaultQuote)
        // Difficulty and max mistakes from settings, not from quote
        game.difficulty = SettingsState.shared.gameDifficulty
        game.maxMistakes = getMaxMistakesForDifficulty(game.difficulty)
        
        self.currentGame = game
    }
    
    // MARK: - Game Setup
    
    /// Set up a custom game
    func setupCustomGame() {
        self.isDailyChallenge = false
        self.dailyQuote = nil
        
        isLoading = true
        errorMessage = nil
        
        // Get random quote from Core Data
        let context = coreData.mainContext
        let fetchRequest = NSFetchRequest<QuoteCD>(entityName: "QuoteCD")
        fetchRequest.predicate = NSPredicate(format: "isActive == YES")
        
        do {
            let quotes = try context.fetch(fetchRequest)
            
            // Get count and pick random
            let count = quotes.count
            if count > 0 {
                // Use a truly random index
                let randomIndex = Int.random(in: 0..<count)
                let quote = quotes[randomIndex]
                
                // Update UI data
                quoteAuthor = quote.author ?? ""
                quoteAttribution = quote.attribution
                
                // Create quote model
                let quoteModel = QuoteModel(
                    text: quote.text ?? "",
                    author: quote.author ?? "",
                    attribution: quote.attribution,
                    difficulty: quote.difficulty
                )
                
                // Create game with quote and appropriate ID
                var newGame = GameModel(quote: quoteModel)
                // Get difficulty from settings instead of quote
                newGame.difficulty = SettingsState.shared.gameDifficulty
                // Set max mistakes based on difficulty settings
                newGame.maxMistakes = getMaxMistakesForDifficulty(newGame.difficulty)
                
                // Create a UUID for the game - store just the UUID in the model
                let gameUUID = UUID()
                newGame.gameId = gameUUID.uuidString // Store as a string for compatibility
                
                currentGame = newGame
                
                showWinMessage = false
                showLoseMessage = false
                
                // Update quote usage count in background
                coreData.performBackgroundTask { bgContext in
                    if let quoteID = quote.id {
                        // Get the object in this background context
                        let objectID = quote.objectID
                        let backgroundQuote = bgContext.object(with: objectID) as! QuoteCD
                        backgroundQuote.timesUsed += 1
                        
                        do {
                            try bgContext.save()
                        } catch {
                            print("Failed to update quote usage count: \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                // No quotes found, use fallback
                errorMessage = "No quotes available"
                useFallbackQuote()
            }
        } catch {
            errorMessage = "Failed to load a quote: \(error.localizedDescription)"
            useFallbackQuote()
        }
        
        isLoading = false
    }
    
    private func useFallbackQuote() {
        // Use fallback quote
        let fallbackQuote = QuoteModel(
            text: "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG",
            author: "Anonymous",
            attribution: nil,
            difficulty: nil
        )
        var game = GameModel(quote: fallbackQuote)
        // Get difficulty from settings
        game.difficulty = SettingsState.shared.gameDifficulty
        // Set max mistakes based on difficulty settings
        game.maxMistakes = getMaxMistakesForDifficulty(game.difficulty)
        currentGame = game
    }
    
    /// Set up the daily challenge
    func setupDailyChallenge() {
        self.isDailyChallenge = true
        
        isLoading = true
        errorMessage = nil
        
        // Try to get daily challenge locally from Core Data
        let context = coreData.mainContext
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        
        // Find quote for today
        let fetchRequest = NSFetchRequest<QuoteCD>(entityName: "QuoteCD")
        fetchRequest.predicate = NSPredicate(format: "isDaily == YES AND dailyDate >= %@ AND dailyDate < %@", today as NSDate, tomorrow as NSDate)
        
        do {
            let quotes = try context.fetch(fetchRequest)
            
            if let dailyQuote = quotes.first {
                setupFromDailyQuote(dailyQuote)
            } else {
                // If not available locally, fetch from API
                fetchDailyQuoteFromAPI()
            }
        } catch {
            errorMessage = "Failed to load daily challenge: \(error.localizedDescription)"
            isLoading = false
        }
    }
    // enable mode to solve until completed
    func enableInfiniteMode() {
        isInfiniteMode = true
        // Remove the loss state but keep the game going
        if var game = currentGame {
            game.hasLost = false
            game.maxMistakes = 999  // Effectively unlimited
            self.currentGame = game
        }
    }
    
    // Helper to set up game from daily quote
    private func setupFromDailyQuote(_ quote: QuoteCD) {
        // Create a daily quote model
        let dailyQuoteModel = DailyQuoteModel(
            id: Int(quote.serverId),
            text: quote.text ?? "",
            author: quote.author ?? "",
            minor_attribution: quote.attribution,
            difficulty: quote.difficulty,
            date: ISO8601DateFormatter().string(from: quote.dailyDate ?? Date()),
            unique_letters: Int(quote.uniqueLetters)
        )
        
        self.dailyQuote = dailyQuoteModel
        
        // Update UI data
        quoteAuthor = quote.author ?? ""
        quoteAttribution = quote.attribution
        
        if let dailyDate = quote.dailyDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            quoteDate = formatter.string(from: dailyDate)
        }
        
        // Create game from quote
        let gameQuote = QuoteModel(
            text: quote.text ?? "",
            author: quote.author ?? "",
            attribution: quote.attribution,
            difficulty: quote.difficulty
        )
        
        var game = GameModel(quote: gameQuote)
        // Set difficulty from settings, not from quote
        game.difficulty = SettingsState.shared.gameDifficulty
        // Set max mistakes based on difficulty settings
        game.maxMistakes = getMaxMistakesForDifficulty(game.difficulty)
        let gameUUID = UUID()
        game.gameId = gameUUID.uuidString // Store as a string
        currentGame = game
        
        showWinMessage = false
        showLoseMessage = false
        isLoading = false
    }
    
    // Fetch daily quote from API if not available locally
    private func fetchDailyQuoteFromAPI() {
        Task {
            do {
                // Get networking service from the auth coordinator
                guard let token = authCoordinator.getAccessToken() else {
                    await MainActor.run {
                        errorMessage = "Authentication required"
                        isLoading = false
                    }
                    return
                }
                
                // Build URL request
                guard let url = URL(string: "\(authCoordinator.baseURL)/api/get_daily") else {
                    await MainActor.run {
                        errorMessage = "Invalid URL configuration"
                        isLoading = false
                    }
                    return
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                // Perform network request
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        errorMessage = "Invalid response from server"
                        isLoading = false
                    }
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    // Parse response
                    let decoder = JSONDecoder()
                    let dailyQuote = try decoder.decode(DailyQuoteModel.self, from: data)
                    
                    // Save to Core Data for future use
                    saveQuoteToCoreData(dailyQuote)
                    
                    // Update UI on main thread
                    await MainActor.run {
                        self.dailyQuote = dailyQuote
                        quoteAuthor = dailyQuote.author
                        quoteAttribution = dailyQuote.minor_attribution
                        quoteDate = dailyQuote.formattedDate
                        
                        // Create game
                        let quoteModel = QuoteModel(
                            text: dailyQuote.text,
                            author: dailyQuote.author,
                            attribution: dailyQuote.minor_attribution,
                            difficulty: dailyQuote.difficulty
                        )
                        
                        var game = GameModel(quote: quoteModel)
                        // Set difficulty and max mistakes from settings
                        game.difficulty = SettingsState.shared.gameDifficulty
                        game.maxMistakes = getMaxMistakesForDifficulty(game.difficulty)
                        game.gameId = "daily-\(dailyQuote.date)" // Mark as daily game with date
                        currentGame = game
                        
                        showWinMessage = false
                        showLoseMessage = false
                        isLoading = false
                    }
                } else {
                    // Handle error responses
                    await MainActor.run {
                        if httpResponse.statusCode == 401 {
                            errorMessage = "Authentication required"
                        } else if httpResponse.statusCode == 404 {
                            errorMessage = "No daily challenge available today"
                        } else {
                            errorMessage = "Server error (\(httpResponse.statusCode))"
                        }
                        isLoading = false
                    }
                }
            } catch {
                // Handle network or parsing errors
                await MainActor.run {
                    errorMessage = "Failed to load daily challenge: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    // Save daily quote to Core Data for offline use
    private func saveQuoteToCoreData(_ dailyQuote: DailyQuoteModel) {
        let context = CoreDataStack.shared.newBackgroundContext()
        
        context.perform {
            // Create date object from ISO string
            let dateFormatter = ISO8601DateFormatter()
            guard let quoteDate = dateFormatter.date(from: dailyQuote.date) else { return }
            
            // Create new QuoteCD entity
            let quote = QuoteCD(context: context)
            quote.id = UUID()
            quote.serverId = Int32(dailyQuote.id)
            quote.text = dailyQuote.text
            quote.author = dailyQuote.author
            quote.attribution = dailyQuote.minor_attribution
            quote.difficulty = dailyQuote.difficulty
            quote.isDaily = true
            quote.dailyDate = quoteDate
            quote.uniqueLetters = Int16(dailyQuote.unique_letters)
            quote.isActive = true
            quote.timesUsed = 0
            
            do {
                try context.save()
            } catch {
                print("Error saving daily quote: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Game State Management
    
    /// Check for an in-progress game
    func checkForInProgressGame() {
        let context = coreData.mainContext
        
        // Query for unfinished games
        let fetchRequest = NSFetchRequest<GameCD>(entityName: "GameCD")
        
        // Add isDaily filter based on current mode
        let dailyPredicate = NSPredicate(format: "isDaily == %@", NSNumber(value: isDailyChallenge))
        let unfinishedPredicate = NSPredicate(format: "hasWon == NO AND hasLost == NO")
        
        // Combine predicates
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            dailyPredicate, unfinishedPredicate
        ])
        
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastUpdateTime", ascending: false)]
        fetchRequest.fetchLimit = 1
        
        do {
            let games = try context.fetch(fetchRequest)
            if let latestGame = games.first {
                // Convert to model
                let gameModel = latestGame.toModel()
                self.savedGame = gameModel
                self.showContinueGameModal = true
            }
        } catch {
            print("Error checking for in-progress game: \(error)")
        }
    }
    
    /// Continue a saved game
    func continueSavedGame() {
        if let savedGame = savedGame {
            currentGame = savedGame
            
            // Get quote info if available
            let context = coreData.mainContext
            let fetchRequest = NSFetchRequest<QuoteCD>(entityName: "QuoteCD")
            fetchRequest.predicate = NSPredicate(format: "text == %@", savedGame.solution)
            
            do {
                let quotes = try context.fetch(fetchRequest)
                if let quote = quotes.first {
                    quoteAuthor = quote.author ?? ""
                    quoteAttribution = quote.attribution
                }
            } catch {
                print("Error fetching quote for game: \(error.localizedDescription)")
            }
            
            self.showContinueGameModal = false
            self.savedGame = nil
        }
    }
    
    /// Reset the current game
    func resetGame() {
        isInfiniteMode = false 
        // If there was a saved game, mark it as abandoned
        if let oldGameId = savedGame?.gameId {
            markGameAsAbandoned(gameId: oldGameId)
        }
        
        if isDailyChallenge, let dailyQuote = dailyQuote {
            // Reuse the daily quote
            let gameQuote = QuoteModel(
                text: dailyQuote.text,
                author: dailyQuote.author,
                attribution: dailyQuote.minor_attribution,
                difficulty: dailyQuote.difficulty
            )
            var game = GameModel(quote: gameQuote)
            // Set difficulty from settings
            game.difficulty = SettingsState.shared.gameDifficulty
            // Set max mistakes based on difficulty settings
            game.maxMistakes = getMaxMistakesForDifficulty(game.difficulty)
            game.gameId = "daily-\(dailyQuote.date)" // Mark as daily game with date
            currentGame = game
            showWinMessage = false
            showLoseMessage = false
        } else {
            // Load a new random game
            setupCustomGame()
        }
        
        // Clear the saved game reference
        self.savedGame = nil
    }
    
    // Mark a game as abandoned
    private func markGameAsAbandoned(gameId: String) {
        let context = coreData.mainContext
        
        // Find the game
        let fetchRequest = NSFetchRequest<GameCD>(entityName: "GameCD")
        fetchRequest.predicate = NSPredicate(format: "gameId == %@", gameId)
        
        do {
            let games = try context.fetch(fetchRequest)
            if let game = games.first {
                game.hasLost = true
                
                // Reset streak if player had one
                if let user = game.user, let stats = user.stats, stats.currentStreak > 0 {
                    stats.currentStreak = 0
                }
                
                try context.save()
            }
        } catch {
            print("Error marking game as abandoned: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Game Actions
    
    /// Handle a player's guess
    func makeGuess(_ guessedLetter: Character) {
        guard var game = currentGame else { return }
        
        // Only proceed if a letter is selected
        if game.selectedLetter != nil {
            let wasCorrect = game.makeGuess(guessedLetter)
            self.currentGame = game
            
            // Save game state
            printGameDetails() // Debug
            saveGameState(game)
            
            // Check game status
            if game.hasWon {
                print("🎉 [GameState] Game won! Updating stats...")
                updateUserStatsForCompletion(game: game)
                showWinMessage = true
            } else if game.hasLost {
                print("😢 [GameState] Game lost! Updating stats...")
                updateUserStatsForCompletion(game: game)
                showLoseMessage = true
            }
        }
    }
    
    /// Select a letter to decode
    func selectLetter(_ letter: Character) {
        guard var game = currentGame else { return }
        game.selectLetter(letter)
        self.currentGame = game
    }
    
    /// Get a hint
    func getHint() {
        guard var game = currentGame else { return }
        
        // Only allow getting hints if we haven't reached the maximum mistakes
        if game.mistakes < game.maxMistakes {
            let _ = game.getHint()
            self.currentGame = game
            
            // Play hint sound
            SoundManager.shared.play(.hint)
            
            // Save game state
            printGameDetails() // Debug
            saveGameState(game)
            
            // Check game status after hint
            if game.hasWon {
                print("🎉 [GameState] Game won (after hint)! Updating stats...")
                updateUserStatsForCompletion(game: game)
                showWinMessage = true
            } else if game.hasLost {
                print("😢 [GameState] Game lost (after hint)! Updating stats...")
                updateUserStatsForCompletion(game: game)
                showLoseMessage = true
            }
        }
    }
    //debug tool for game state
    func printGameDetails() {
        if let game = currentGame {
            print("Current Game ID: \(game.gameId ?? "nil")")
            if let gameId = game.gameId, let uuid = UUID(uuidString: gameId) {
                print("Valid UUID format: \(uuid.uuidString)")
            } else {
                print("Not a valid UUID format")
            }
            print("Is Daily Challenge: \(isDailyChallenge)")
            print("Current mistakes: \(game.mistakes)/\(game.maxMistakes)")
        } else {
            print("No current game")
        }
    }
    
    //helper for updating user stats
    private func updateUserStatsForCompletion(game: GameModel) {
        print("📊 [GameState] Updating user stats for game completion")
        
        // Calculate final values
        let score = game.calculateScore()
        let timeTaken = Int(game.lastUpdateTime.timeIntervalSince(game.startTime))
        
        print("   Final Score: \(score)")
        print("   Time Taken: \(timeTaken)s")
        print("   Mistakes: \(game.mistakes)")
        print("   Won: \(game.hasWon)")
        
        // Update user stats
        UserState.shared.updateStats(
            gameWon: game.hasWon,
            score: score,
            timeTaken: timeTaken,
            mistakes: game.mistakes
        )
        
        // Also ensure the game is in the sync queue
        if game.hasWon || game.hasLost {
            print("📤 [GameState] Uploading completed game")
            GameSyncManager.shared.uploadCompletedGame(game)
        }
    }

    // Save current game state to Core Data
    private func convertToGameModel(_ game: GameCD) -> GameModel {
        var mapping: [Character: Character] = [:]
        var correctMappings: [Character: Character] = [:]
        var guessedMappings: [Character: Character] = [:]
        
        // Deserialize mappings
        if let mappingData = game.mapping,
           let mappingDict = try? JSONDecoder().decode([String: String].self, from: mappingData) {
            mapping = stringDictionaryToCharacterDictionary(mappingDict)
        }
        
        if let correctMappingsData = game.correctMappings,
           let correctDict = try? JSONDecoder().decode([String: String].self, from: correctMappingsData) {
            correctMappings = stringDictionaryToCharacterDictionary(correctDict)
        }
        
        if let guessedMappingsData = game.guessedMappings,
           let guessedDict = try? JSONDecoder().decode([String: String].self, from: guessedMappingsData) {
            guessedMappings = stringDictionaryToCharacterDictionary(guessedDict)
        }
        
        return GameModel(
            gameId: game.gameId?.uuidString ?? "", // Convert UUID to String
            encrypted: game.encrypted ?? "",
            solution: game.solution ?? "",
            currentDisplay: game.currentDisplay ?? "",
            mapping: mapping,
            correctMappings: correctMappings,
            guessedMappings: guessedMappings,
            mistakes: Int(game.mistakes),
            maxMistakes: Int(game.maxMistakes),
            hasWon: game.hasWon,
            hasLost: game.hasLost,
            difficulty: game.difficulty ?? "medium",
            startTime: game.startTime ?? Date(),
            lastUpdateTime: game.lastUpdateTime ?? Date()
        )
    }
    
    // Create a new game entity from model
    private func createGameEntity(from model: GameModel) -> GameCD {
        let context = coreData.mainContext
        let gameEntity = GameCD(context: context)
        
        gameEntity.gameId = UUID() 
        gameEntity.startTime = model.startTime
        
        updateGameEntity(gameEntity, from: model)
        return gameEntity
    }
    
    // Update game entity from model
    private func updateGameEntity(_ entity: GameCD, from model: GameModel) {
        entity.encrypted = model.encrypted
        entity.solution = model.solution
        entity.currentDisplay = model.currentDisplay
        entity.mistakes = Int16(model.mistakes)
        entity.maxMistakes = Int16(model.maxMistakes)
        entity.hasWon = model.hasWon
        entity.hasLost = model.hasLost
        entity.difficulty = model.difficulty
        entity.lastUpdateTime = model.lastUpdateTime
        entity.isDaily = isDailyChallenge
        
        // Serialize mappings
        do {
            entity.mapping = try JSONEncoder().encode(characterDictionaryToStringDictionary(model.mapping))
            entity.correctMappings = try JSONEncoder().encode(characterDictionaryToStringDictionary(model.correctMappings))
            entity.guessedMappings = try JSONEncoder().encode(characterDictionaryToStringDictionary(model.guessedMappings))
            var incorrectDict: [String: [String]] = [:]
                    for (key, values) in model.incorrectGuesses {
                        incorrectDict[String(key)] = values.map { String($0) }
                    }
                    entity.incorrectGuesses = try JSONEncoder().encode(incorrectDict)
        } catch {
            print("Error encoding mappings: \(error.localizedDescription)")
        }
    }
    //tidy DB in case of error
    func cleanupDuplicateGames() {
        let context = coreData.mainContext
        
        // Get all games
        let fetchRequest = NSFetchRequest<GameCD>(entityName: "GameCD")
        
        do {
            let allGames = try context.fetch(fetchRequest)
            print("Found \(allGames.count) total game records")
            
            // Dictionary to count occurrences of each game ID
            var gameIDCounts: [UUID: Int] = [:]
            var gameIDObjects: [UUID: [GameCD]] = [:]
            
            // Count occurrences of each game ID
            for game in allGames {
                if let id = game.gameId {
                    print("Game ID: \(id)")
                    gameIDCounts[id, default: 0] += 1
                    
                    if gameIDObjects[id] == nil {
                        gameIDObjects[id] = [game]
                    } else {
                        gameIDObjects[id]?.append(game)
                    }
                } else {
                    print("Warning: Found game record with nil gameId")
                }
            }
            
            // Find IDs with multiple occurrences
            let duplicateIDs = gameIDCounts.filter { $0.value > 1 }.keys
            print("Found \(gameIDCounts.count) unique game IDs")
            print("Found \(duplicateIDs.count) IDs with duplicates")
            
            // Clean up duplicates
            var deletedCount = 0
            
            for id in duplicateIDs {
                guard let games = gameIDObjects[id], games.count > 1 else { continue }
                
                print("Game ID \(id.uuidString) has \(games.count) duplicates")
                
                // Sort by last update time (newest first)
                let sortedGames = games.sorted {
                    ($0.lastUpdateTime ?? Date.distantPast) > ($1.lastUpdateTime ?? Date.distantPast)
                }
                
                // Keep the newest, delete the rest
                for i in 1..<sortedGames.count {
                    let game = sortedGames[i]
                    context.delete(game)
                    deletedCount += 1
                    print("  Deleted duplicate updated at: \(game.lastUpdateTime ?? Date.distantPast)")
                }
                
                print("  Kept newest updated at: \(sortedGames[0].lastUpdateTime ?? Date.distantPast)")
            }
            
            if duplicateIDs.isEmpty {
                print("✅ No duplicates found - database is clean!")
            } else {
                print("🧹 Cleanup complete. Deleted \(deletedCount) duplicate records")
            }
            
            // Save changes
            if context.hasChanges {
                try context.save()
            }
        } catch {
            print("❌ Error during cleanup: \(error.localizedDescription)")
        }
    }
    /// Submit score for daily challenge
    func submitDailyScore(userId: String) {
        guard let game = currentGame, game.hasWon || game.hasLost else { return }
        
        let context = coreData.mainContext
        let userFetchRequest = NSFetchRequest<UserCD>(entityName: "UserCD")
        userFetchRequest.predicate = NSPredicate(format: "userId == %@", userId)
        
        do {
            let users = try context.fetch(userFetchRequest)
            
            if let user = users.first {
                // Get or create stats
                let stats: UserStatsCD
                if let existingStats = user.stats {
                    stats = existingStats
                } else {
                    stats = UserStatsCD(context: context)
                    user.stats = stats
                    stats.user = user
                }
                
                // Calculate final values
                let finalScore = game.calculateScore()
                let timeTaken = Int(game.lastUpdateTime.timeIntervalSince(game.startTime))
                
                // Update stats
                stats.gamesPlayed += 1
                if game.hasWon {
                    stats.gamesWon += 1
                    stats.currentStreak += 1
                    stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
                } else {
                    stats.currentStreak = 0
                }
                
                stats.totalScore += Int32(finalScore)
                
                // Update averages
                let oldMistakesTotal = stats.averageMistakes * Double(stats.gamesPlayed - 1)
                stats.averageMistakes = (oldMistakesTotal + Double(game.mistakes)) / Double(stats.gamesPlayed)
                
                let oldTimeTotal = stats.averageTime * Double(stats.gamesPlayed - 1)
                stats.averageTime = (oldTimeTotal + Double(timeTaken)) / Double(stats.gamesPlayed)
                
                stats.lastPlayedDate = Date()
                
                // Save changes
                try context.save()
            }
        } catch {
            print("Error updating user stats: \(error.localizedDescription)")
        }
    }
    
    /// Reset the state
    func reset() {
        currentGame = nil
        savedGame = nil
        isLoading = false
        errorMessage = nil
        showWinMessage = false
        showLoseMessage = false
        showContinueGameModal = false
        quoteAuthor = ""
        quoteAttribution = nil
        quoteDate = nil
        isDailyChallenge = false
        setupDefaultGame()
    }
    
    // Helper for time formatting
    func formatTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let seconds = seconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // Helper functions for character dictionary conversions
    private func characterDictionaryToStringDictionary(_ dict: [Character: Character]) -> [String: String] {
        var result = [String: String]()
        for (key, value) in dict {
            result[String(key)] = String(value)
        }
        return result
    }
    
    private func saveGameState(_ game: GameModel) {
        // Don't save if we're in infinite mode (post-loss practice)
        guard !isInfiniteMode else { return }
        
        guard let gameId = game.gameId else {
            print("❌ [GameState] Error: Trying to save game state with no game ID")
            return
        }
        
        let context = coreData.mainContext
        
        // Try to convert to UUID
        guard let gameUUID = UUID(uuidString: gameId) else {
            print("❌ [GameState] Error: Invalid UUID format in game ID: \(gameId)")
            return
        }
        
        print("💾 [GameState] Saving game state")
        print("   Game ID: \(gameId)")
        print("   User ID: \(UserState.shared.userId)")
        print("   Is Authenticated: \(UserState.shared.isAuthenticated)")
        
        // Try to find the existing game
        let fetchRequest = NSFetchRequest<GameCD>(entityName: "GameCD")
        fetchRequest.predicate = NSPredicate(format: "gameId == %@", gameUUID as CVarArg)
        
        do {
            let existingGames = try context.fetch(fetchRequest)
            
            let gameEntity: GameCD
            if let existingGame = existingGames.first {
                print("   Updating existing game")
                gameEntity = existingGame
                updateGameEntity(gameEntity, from: game)
            } else {
                print("   Creating new game")
                gameEntity = GameCD(context: context)
                gameEntity.gameId = gameUUID
                gameEntity.startTime = game.startTime
                updateGameEntity(gameEntity, from: game)
            }
            
            // IMPORTANT: Set user relationship if available
            if UserState.shared.isAuthenticated && !UserState.shared.userId.isEmpty {
                let userFetchRequest = NSFetchRequest<UserCD>(entityName: "UserCD")
                userFetchRequest.predicate = NSPredicate(format: "userId == %@", UserState.shared.userId)
                let users = try context.fetch(userFetchRequest)
                
                if let user = users.first {
                    gameEntity.user = user
                    print("   ✅ Set user relationship: \(user.username ?? "unknown")")
                } else {
                    print("   ⚠️ User not found in Core Data - creating new user")
                    // Create user if needed
                    let newUser = UserCD(context: context)
                    newUser.id = UUID()
                    newUser.userId = UserState.shared.userId
                    newUser.username = UserState.shared.username
                    newUser.email = "\(UserState.shared.username)@example.com"
                    newUser.registrationDate = Date()
                    newUser.lastLoginDate = Date()
                    newUser.isActive = true
                    gameEntity.user = newUser
                }
            } else {
                print("   ⚠️ No authenticated user - game will not be linked to user")
            }
            
            // Update score and time if completed
            if game.hasWon || game.hasLost {
                gameEntity.score = Int32(game.calculateScore())
                gameEntity.timeTaken = Int32(game.lastUpdateTime.timeIntervalSince(game.startTime))
                print("   Game completed - Score: \(gameEntity.score), Time: \(gameEntity.timeTaken)s")
            }
            
            try context.save()
            print("   ✅ Game saved successfully")
            
        } catch {
            print("❌ [GameState] Error saving game state: \(error.localizedDescription)")
        }
    }
    private func stringDictionaryToCharacterDictionary(_ dict: [String: String]) -> [Character: Character] {
        var result = [Character: Character]()
        for (key, value) in dict {
            if let keyChar = key.first, let valueChar = value.first {
                result[keyChar] = valueChar
            }
        }
        return result
    }
}
