// Entities, value types and ports shared by features and adapters. Foundation only; never imports MotionCore.
//
// - Identifiers.swift: EntityID (UUIDv7), ExerciseID (slug), UUIDv7 generator
// - LocalDay.swift, Units.swift: calendar day, Mass, Length, Energy, UnitSystem
// - ProfileAndGoal.swift, Exercise.swift, Workout.swift, Nutrition.swift, Coach.swift, HealthAndSettings.swift: entities
// - GoalPlanner.swift: energy and macro targets
// - WorkoutSessionReducer.swift: the active-workout state machine
// - Ports.swift: Sendable store protocols implemented by Persistence
