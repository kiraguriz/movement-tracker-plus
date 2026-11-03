// The exact requests CoachKit sends, one per feature, as GoldenRender prints them.
// Regenerate with: COACHKIT_GOLDEN_DIR=<dir> swift test --package-path Packages/MovementKit --filter "GoldenRequestTests|ChatTurnTests|PromptPinTests",
// then copy <dir>/<name>.txt into the matching constant and <dir>/pins.txt into PromptPins.swift.
enum Goldens {
    static let setReview = #"""
    POST /v1/coach/responses
    X-Coach-Feature: set_review
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 2849 characters, sha256 1e959935501d4956>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "day": "2026-10-29",
                "exercise": {
                  "id": "squat.bodyweight",
                  "name": "Bodyweight Squat",
                  "specVersion": 1
                },
                "images": [
                  {
                    "rep": 3,
                    "role": "best_rep_bottom"
                  },
                  {
                    "rep": 4,
                    "role": "worst_rep_bottom"
                  }
                ],
                "lastComparable": {
                  "avgScore": 71.2,
                  "day": "2026-10-27",
                  "issues": {
                    "depth": 4
                  },
                  "partialReps": 0,
                  "reps": 5,
                  "velocityLossPct": 25
                },
                "reps": [
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 1,
                    "rom": 0.81,
                    "score": 95
                  },
                  {
                    "bottom": 0.22,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.deeper",
                        "rule": "depth",
                        "severity": "major"
                      }
                    ],
                    "rep": 2,
                    "rom": 0.81,
                    "score": 62
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 3,
                    "rom": 0.81,
                    "score": 93
                  },
                  {
                    "bottom": 0.25,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.deeper",
                        "rule": "depth",
                        "severity": "major"
                      }
                    ],
                    "rep": 4,
                    "rom": 0.81,
                    "score": 58
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.chestUp",
                        "rule": "chest",
                        "severity": "minor"
                      }
                    ],
                    "rep": 5,
                    "rom": 0.81,
                    "score": 80
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 6,
                    "rom": 0.81,
                    "score": 91
                  }
                ],
                "set": {
                  "avgScore": 79.8,
                  "loadKg": 20,
                  "partialReps": 1,
                  "reps": 6,
                  "velocityLossPct": 18
                },
                "user": {
                  "goal": "lose",
                  "level": "beginner",
                  "units": "metric"
                },
                "voiceNote": "left knee felt tight"
              },
              "text": "Review this set. The attached images follow the `images` list, in order.",
              "type": "input_text"
            },
            {
              "image_url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAAAAAAAAAAAIElEQVQREREREREREREREREREREREREREREREREREREREREREQAAAAAAAAAASUVORAAAAAA=",
              "type": "input_image"
            },
            {
              "image_url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAAAAAAAAAAAIElEQVQiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIgAAAAAAAAAASUVORAAAAAA=",
              "type": "input_image"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 5000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "low"
      },
      "store": false,
      "stream": true,
      "text": {
        "format": {
          "name": "SetReview",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "confidence": {
                "description": "0 to 1: how well the data supports this review.",
                "type": "number"
              },
              "fixNext": {
                "description": "At most 2 fixes, most important first. Empty when no rep has an issue.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "cue": {
                      "description": "Short imperative for the next set, at most 10 words.",
                      "type": "string"
                    },
                    "repRefs": {
                      "description": "Numbers of the reps where this was measured, as numbered in the data. Never empty.",
                      "items": {
                        "type": "integer"
                      },
                      "type": "array"
                    },
                    "why": {
                      "description": "One sentence linking the cue to what was measured.",
                      "type": "string"
                    }
                  },
                  "required": [
                    "cue",
                    "why",
                    "repRefs"
                  ],
                  "type": "object"
                },
                "type": "array"
              },
              "headline": {
                "description": "One sentence, at most 14 words: the main takeaway of this set.",
                "type": "string"
              },
              "nextSet": {
                "additionalProperties": false,
                "properties": {
                  "loadChangePct": {
                    "description": "Percent change of the load versus this set; 0 for bodyweight or unknown load.",
                    "type": "number"
                  },
                  "reps": {
                    "description": "Target reps for the next set.",
                    "type": "integer"
                  },
                  "restSec": {
                    "description": "Rest before the next set, in seconds.",
                    "type": "integer"
                  },
                  "tempo": {
                    "description": "For example \"3 s down, 1 s up\".",
                    "type": "string"
                  }
                },
                "required": [
                  "reps",
                  "loadChangePct",
                  "restSec",
                  "tempo"
                ],
                "type": "object"
              },
              "safetyFlag": {
                "additionalProperties": false,
                "properties": {
                  "level": {
                    "description": "none, caution or stop.",
                    "enum": [
                      "none",
                      "caution",
                      "stop"
                    ],
                    "type": "string"
                  },
                  "note": {
                    "description": "Short note; empty when level is none.",
                    "type": "string"
                  }
                },
                "required": [
                  "level",
                  "note"
                ],
                "type": "object"
              },
              "wentWell": {
                "description": "1 to 3 short points tied to the measured data.",
                "items": {
                  "type": "string"
                },
                "type": "array"
              }
            },
            "required": [
              "headline",
              "wentWell",
              "fixNext",
              "nextSet",
              "safetyFlag",
              "confidence"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"
    static let setReviewChinese = #"""
    POST /v1/coach/responses
    X-Coach-Feature: set_review
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 2867 characters, sha256 c71d3779ef136efb>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "day": "2026-10-29",
                "exercise": {
                  "id": "squat.bodyweight",
                  "name": "Bodyweight Squat",
                  "specVersion": 1
                },
                "lastComparable": {
                  "avgScore": 71.2,
                  "day": "2026-10-27",
                  "issues": {
                    "depth": 4
                  },
                  "partialReps": 0,
                  "reps": 5,
                  "velocityLossPct": 25
                },
                "reps": [
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 1,
                    "rom": 0.81,
                    "score": 95
                  },
                  {
                    "bottom": 0.22,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.deeper",
                        "rule": "depth",
                        "severity": "major"
                      }
                    ],
                    "rep": 2,
                    "rom": 0.81,
                    "score": 62
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 3,
                    "rom": 0.81,
                    "score": 93
                  },
                  {
                    "bottom": 0.25,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.deeper",
                        "rule": "depth",
                        "severity": "major"
                      }
                    ],
                    "rep": 4,
                    "rom": 0.81,
                    "score": 58
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.chestUp",
                        "rule": "chest",
                        "severity": "minor"
                      }
                    ],
                    "rep": 5,
                    "rom": 0.81,
                    "score": 80
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 6,
                    "rom": 0.81,
                    "score": 91
                  }
                ],
                "set": {
                  "avgScore": 79.8,
                  "partialReps": 1,
                  "reps": 6,
                  "velocityLossPct": 18
                },
                "user": {
                  "goal": "lose",
                  "level": "beginner",
                  "units": "metric"
                }
              },
              "text": "Review this set.",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 5000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "low"
      },
      "store": false,
      "stream": true,
      "text": {
        "format": {
          "name": "SetReview",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "confidence": {
                "description": "0 to 1: how well the data supports this review.",
                "type": "number"
              },
              "fixNext": {
                "description": "At most 2 fixes, most important first. Empty when no rep has an issue.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "cue": {
                      "description": "Short imperative for the next set, at most 10 words.",
                      "type": "string"
                    },
                    "repRefs": {
                      "description": "Numbers of the reps where this was measured, as numbered in the data. Never empty.",
                      "items": {
                        "type": "integer"
                      },
                      "type": "array"
                    },
                    "why": {
                      "description": "One sentence linking the cue to what was measured.",
                      "type": "string"
                    }
                  },
                  "required": [
                    "cue",
                    "why",
                    "repRefs"
                  ],
                  "type": "object"
                },
                "type": "array"
              },
              "headline": {
                "description": "One sentence, at most 14 words: the main takeaway of this set.",
                "type": "string"
              },
              "nextSet": {
                "additionalProperties": false,
                "properties": {
                  "loadChangePct": {
                    "description": "Percent change of the load versus this set; 0 for bodyweight or unknown load.",
                    "type": "number"
                  },
                  "reps": {
                    "description": "Target reps for the next set.",
                    "type": "integer"
                  },
                  "restSec": {
                    "description": "Rest before the next set, in seconds.",
                    "type": "integer"
                  },
                  "tempo": {
                    "description": "For example \"3 s down, 1 s up\".",
                    "type": "string"
                  }
                },
                "required": [
                  "reps",
                  "loadChangePct",
                  "restSec",
                  "tempo"
                ],
                "type": "object"
              },
              "safetyFlag": {
                "additionalProperties": false,
                "properties": {
                  "level": {
                    "description": "none, caution or stop.",
                    "enum": [
                      "none",
                      "caution",
                      "stop"
                    ],
                    "type": "string"
                  },
                  "note": {
                    "description": "Short note; empty when level is none.",
                    "type": "string"
                  }
                },
                "required": [
                  "level",
                  "note"
                ],
                "type": "object"
              },
              "wentWell": {
                "description": "1 to 3 short points tied to the measured data.",
                "items": {
                  "type": "string"
                },
                "type": "array"
              }
            },
            "required": [
              "headline",
              "wentWell",
              "fixNext",
              "nextSet",
              "safetyFlag",
              "confidence"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"
    static let setReviewRepair = #"""
    POST /v1/coach/responses
    X-Coach-Feature: set_review
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 2849 characters, sha256 1e959935501d4956>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "day": "2026-10-29",
                "exercise": {
                  "id": "squat.bodyweight",
                  "name": "Bodyweight Squat",
                  "specVersion": 1
                },
                "lastComparable": {
                  "avgScore": 71.2,
                  "day": "2026-10-27",
                  "issues": {
                    "depth": 4
                  },
                  "partialReps": 0,
                  "reps": 5,
                  "velocityLossPct": 25
                },
                "reps": [
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 1,
                    "rom": 0.81,
                    "score": 95
                  },
                  {
                    "bottom": 0.22,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.deeper",
                        "rule": "depth",
                        "severity": "major"
                      }
                    ],
                    "rep": 2,
                    "rom": 0.81,
                    "score": 62
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 3,
                    "rom": 0.81,
                    "score": 93
                  },
                  {
                    "bottom": 0.25,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.deeper",
                        "rule": "depth",
                        "severity": "major"
                      }
                    ],
                    "rep": 4,
                    "rom": 0.81,
                    "score": 58
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "issues": [
                      {
                        "cue": "cue.squat.chestUp",
                        "rule": "chest",
                        "severity": "minor"
                      }
                    ],
                    "rep": 5,
                    "rom": 0.81,
                    "score": 80
                  },
                  {
                    "bottom": 0.05,
                    "conMs": 900,
                    "conVel": 0.62,
                    "eccMs": 1200,
                    "rep": 6,
                    "rom": 0.81,
                    "score": 91
                  }
                ],
                "set": {
                  "avgScore": 79.8,
                  "partialReps": 1,
                  "reps": 6,
                  "velocityLossPct": 18
                },
                "user": {
                  "goal": "lose",
                  "level": "beginner",
                  "units": "metric"
                }
              },
              "text": "Review this set.",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        },
        {
          "content": [
            {
              "text": "{\"headline\":\"Only a headline\"}",
              "type": "output_text"
            }
          ],
          "role": "assistant",
          "type": "message"
        },
        {
          "content": [
            {
              "text": "Your previous answer was rejected: $.wentWell: is required; $.fixNext: is required; $.nextSet: is required; $.safetyFlag: is required; $.confidence: is required. Answer again with the one JSON object that matches the schema and fixes this. Keep every rule from the instructions.",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 5000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "low"
      },
      "store": false,
      "stream": true,
      "text": {
        "format": {
          "name": "SetReview",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "confidence": {
                "description": "0 to 1: how well the data supports this review.",
                "type": "number"
              },
              "fixNext": {
                "description": "At most 2 fixes, most important first. Empty when no rep has an issue.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "cue": {
                      "description": "Short imperative for the next set, at most 10 words.",
                      "type": "string"
                    },
                    "repRefs": {
                      "description": "Numbers of the reps where this was measured, as numbered in the data. Never empty.",
                      "items": {
                        "type": "integer"
                      },
                      "type": "array"
                    },
                    "why": {
                      "description": "One sentence linking the cue to what was measured.",
                      "type": "string"
                    }
                  },
                  "required": [
                    "cue",
                    "why",
                    "repRefs"
                  ],
                  "type": "object"
                },
                "type": "array"
              },
              "headline": {
                "description": "One sentence, at most 14 words: the main takeaway of this set.",
                "type": "string"
              },
              "nextSet": {
                "additionalProperties": false,
                "properties": {
                  "loadChangePct": {
                    "description": "Percent change of the load versus this set; 0 for bodyweight or unknown load.",
                    "type": "number"
                  },
                  "reps": {
                    "description": "Target reps for the next set.",
                    "type": "integer"
                  },
                  "restSec": {
                    "description": "Rest before the next set, in seconds.",
                    "type": "integer"
                  },
                  "tempo": {
                    "description": "For example \"3 s down, 1 s up\".",
                    "type": "string"
                  }
                },
                "required": [
                  "reps",
                  "loadChangePct",
                  "restSec",
                  "tempo"
                ],
                "type": "object"
              },
              "safetyFlag": {
                "additionalProperties": false,
                "properties": {
                  "level": {
                    "description": "none, caution or stop.",
                    "enum": [
                      "none",
                      "caution",
                      "stop"
                    ],
                    "type": "string"
                  },
                  "note": {
                    "description": "Short note; empty when level is none.",
                    "type": "string"
                  }
                },
                "required": [
                  "level",
                  "note"
                ],
                "type": "object"
              },
              "wentWell": {
                "description": "1 to 3 short points tied to the measured data.",
                "items": {
                  "type": "string"
                },
                "type": "array"
              }
            },
            "required": [
              "headline",
              "wentWell",
              "fixNext",
              "nextSet",
              "safetyFlag",
              "confidence"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"
    static let debrief = #"""
    POST /v1/coach/responses
    X-Coach-Feature: debrief
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 2171 characters, sha256 6460869c41ff2ccf>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "exercises": [
                  {
                    "id": "squat.bodyweight",
                    "name": "Bodyweight Squat",
                    "sets": [
                      {
                        "avgScore": 79.8,
                        "issues": [
                          {
                            "cue": "cue.squat.deeper",
                            "reps": [
                              2,
                              4
                            ],
                            "rule": "depth",
                            "severity": "major"
                          },
                          {
                            "cue": "cue.squat.chestUp",
                            "reps": [
                              5
                            ],
                            "rule": "chest",
                            "severity": "minor"
                          }
                        ],
                        "partialReps": 0,
                        "repScores": [
                          95,
                          62,
                          93,
                          58,
                          80,
                          91
                        ],
                        "reps": 6,
                        "restSec": 90,
                        "set": 1,
                        "tracking": "camera",
                        "velocityLossPct": 10
                      },
                      {
                        "avgScore": 85,
                        "partialReps": 0,
                        "repScores": [
                          90,
                          90,
                          90,
                          90,
                          90
                        ],
                        "reps": 5,
                        "restSec": 90,
                        "set": 2,
                        "tracking": "camera",
                        "velocityLossPct": 10
                      }
                    ]
                  },
                  {
                    "id": "pushup",
                    "name": "Push-up",
                    "sets": [
                      {
                        "avgScore": 88,
                        "partialReps": 0,
                        "repScores": [
                          88,
                          88,
                          88,
                          88,
                          88,
                          88,
                          88,
                          88
                        ],
                        "reps": 8,
                        "restSec": 90,
                        "set": 1,
                        "tracking": "camera",
                        "velocityLossPct": 10
                      }
                    ]
                  }
                ],
                "session": {
                  "day": "2026-10-29",
                  "durationMin": 45,
                  "title": "Legs"
                },
                "user": {
                  "goal": "lose",
                  "level": "beginner",
                  "units": "metric"
                }
              },
              "text": "Debrief this session and suggest the next one.",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 6000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "medium"
      },
      "store": false,
      "stream": true,
      "text": {
        "format": {
          "name": "SessionDebrief",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "concerns": {
                "description": "Up to 3 form or fatigue problems.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "detail": {
                      "description": "Short detail.",
                      "type": "string"
                    },
                    "exerciseID": {
                      "description": "The exercise id from the data.",
                      "type": "string"
                    },
                    "setNumbers": {
                      "description": "Set numbers within that exercise where it showed.",
                      "items": {
                        "type": "integer"
                      },
                      "type": "array"
                    }
                  },
                  "required": [
                    "exerciseID",
                    "setNumbers",
                    "detail"
                  ],
                  "type": "object"
                },
                "type": "array"
              },
              "confidence": {
                "description": "0 to 1.",
                "type": "number"
              },
              "headline": {
                "description": "One sentence, at most 14 words.",
                "type": "string"
              },
              "highlights": {
                "description": "Up to 3 short points about what went well.",
                "items": {
                  "type": "string"
                },
                "type": "array"
              },
              "nextSession": {
                "additionalProperties": false,
                "properties": {
                  "focus": {
                    "description": "One sentence on what to focus on next time.",
                    "type": "string"
                  },
                  "restDaysSuggested": {
                    "description": "Rest days before the next session, 0 to 7.",
                    "type": "integer"
                  },
                  "suggestions": {
                    "description": "Up to 4 suggestions.",
                    "items": {
                      "additionalProperties": false,
                      "properties": {
                        "exercise": {
                          "description": "An exercise id from the data, or an exercise name.",
                          "type": "string"
                        },
                        "loadChangePct": {
                          "description": "Percent change of the load versus this session; 0 for bodyweight or unknown load.",
                          "type": "number"
                        },
                        "note": {
                          "description": "Short note; may be empty.",
                          "type": "string"
                        },
                        "reps": {
                          "type": "integer"
                        },
                        "restSec": {
                          "type": "integer"
                        },
                        "sets": {
                          "type": "integer"
                        }
                      },
                      "required": [
                        "exercise",
                        "sets",
                        "reps",
                        "loadChangePct",
                        "restSec",
                        "note"
                      ],
                      "type": "object"
                    },
                    "type": "array"
                  }
                },
                "required": [
                  "focus",
                  "suggestions",
                  "restDaysSuggested"
                ],
                "type": "object"
              },
              "perExercise": {
                "description": "One entry per exercise in the session.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "exerciseID": {
                      "description": "The exercise id from the data.",
                      "type": "string"
                    },
                    "note": {
                      "description": "One sentence.",
                      "type": "string"
                    },
                    "verdict": {
                      "description": "progress, steady, regress, mixed or first_time.",
                      "enum": [
                        "progress",
                        "steady",
                        "regress",
                        "mixed",
                        "first_time"
                      ],
                      "type": "string"
                    }
                  },
                  "required": [
                    "exerciseID",
                    "verdict",
                    "note"
                  ],
                  "type": "object"
                },
                "type": "array"
              },
              "safetyFlag": {
                "additionalProperties": false,
                "properties": {
                  "level": {
                    "description": "none, caution or stop.",
                    "enum": [
                      "none",
                      "caution",
                      "stop"
                    ],
                    "type": "string"
                  },
                  "note": {
                    "description": "Short note; empty when level is none.",
                    "type": "string"
                  }
                },
                "required": [
                  "level",
                  "note"
                ],
                "type": "object"
              },
              "summary": {
                "description": "Two or three sentences on how the session went, using the measured numbers.",
                "type": "string"
              }
            },
            "required": [
              "headline",
              "summary",
              "highlights",
              "perExercise",
              "concerns",
              "nextSession",
              "safetyFlag",
              "confidence"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"
    static let mealPhoto = #"""
    POST /v1/coach/responses
    X-Coach-Feature: meal_photo
    Accept: application/json
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 1308 characters, sha256 94a209263b1c4460>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "note": "two eggs and toast",
                "task": "Estimate the foods and portions in the attached photo of a meal.",
                "units": "metric"
              },
              "text": "",
              "type": "input_text"
            },
            {
              "image_url": "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/wAALCAABAAEBAREA/9oACAEBAAA/ACIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiL/2Q==",
              "type": "input_image"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 4000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "low"
      },
      "store": false,
      "text": {
        "format": {
          "name": "MealEstimate",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "items": {
                "description": "Each distinct food in the photo; empty when there is no food.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "confidence": {
                      "description": "0 to 1.",
                      "type": "number"
                    },
                    "gramsEstimate": {
                      "description": "Best estimate of the eaten weight in grams.",
                      "type": "number"
                    },
                    "name": {
                      "description": "What the user will read, in the user's language.",
                      "type": "string"
                    },
                    "usdaQuery": {
                      "description": "English, generic USDA FoodData Central search phrase, 2 to 100 characters.",
                      "type": "string"
                    }
                  },
                  "required": [
                    "name",
                    "gramsEstimate",
                    "confidence",
                    "usdaQuery"
                  ],
                  "type": "object"
                },
                "type": "array"
              },
              "notes": {
                "description": "One or two sentences about the biggest uncertainty.",
                "type": "string"
              }
            },
            "required": [
              "items",
              "notes"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"
    static let chatFirstTurn = #"""
    POST /v1/coach/responses
    X-Coach-Feature: chat
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 1930 characters, sha256 7896fc54c2e3c2c7>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "text": "How was my last squat session?",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 6000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "medium"
      },
      "store": false,
      "stream": true,
      "tools": [
        {
          "description": "Summaries of the user's recent workout sessions, newest first: date, exercises, sets with reps, load, average form score and velocity loss. Use before talking about their training.",
          "name": "get_sessions",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "days": {
                "description": "How many days back to look, 1 to 90.",
                "maximum": 90,
                "minimum": 1,
                "type": "integer"
              }
            },
            "required": [
              "days"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "One set in detail, rep by rep: score, timing, range of motion and rule issues. Use a set id from get_sessions.",
          "name": "get_set_detail",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "set_id": {
                "description": "A set id returned by get_sessions.",
                "type": "string"
              }
            },
            "required": [
              "set_id"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "The user's logged meals and macro totals for one day.",
          "name": "get_nutrition",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "day": {
                "description": "A date as yyyy-MM-dd, or \"today\", or \"yesterday\".",
                "type": "string"
              }
            },
            "required": [
              "day"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "The user's body weight (kg) and body fat (percent) measurements over a period: first, latest, change and a few points.",
          "name": "get_body_trend",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "days": {
                "description": "How many days back to look, 1 to 365.",
                "maximum": 365,
                "minimum": 1,
                "type": "integer"
              }
            },
            "required": [
              "days"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "The user's active goal (kind, target, calories, macros, workouts per week) and basic profile (age, height, units, training level). No name.",
          "name": "get_goal",
          "parameters": {
            "additionalProperties": false,
            "properties": {},
            "required": [],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "Propose a weekly training plan. Nothing is saved: the user sees the proposal and must confirm it in the app.",
          "name": "propose_plan",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "plan": {
                "additionalProperties": false,
                "properties": {
                  "rationale": {
                    "description": "One or two sentences why this plan fits the user.",
                    "type": "string"
                  },
                  "sessions": {
                    "description": "The training days of one week, 1 to 7.",
                    "items": {
                      "additionalProperties": false,
                      "properties": {
                        "exercises": {
                          "description": "1 to 12 exercises.",
                          "items": {
                            "additionalProperties": false,
                            "properties": {
                              "name": {
                                "description": "Exercise name.",
                                "type": "string"
                              },
                              "note": {
                                "description": "Short note; may be empty.",
                                "type": "string"
                              },
                              "reps": {
                                "description": "Reps per set, 1 to 50.",
                                "maximum": 50,
                                "minimum": 1,
                                "type": "integer"
                              },
                              "restSec": {
                                "description": "Rest between sets in seconds, 15 to 600.",
                                "maximum": 600,
                                "minimum": 15,
                                "type": "integer"
                              },
                              "sets": {
                                "description": "Sets, 1 to 10.",
                                "maximum": 10,
                                "minimum": 1,
                                "type": "integer"
                              }
                            },
                            "required": [
                              "name",
                              "sets",
                              "reps",
                              "restSec",
                              "note"
                            ],
                            "type": "object"
                          },
                          "maxItems": 12,
                          "minItems": 1,
                          "type": "array"
                        },
                        "name": {
                          "description": "For example \"Day 1: legs\".",
                          "type": "string"
                        }
                      },
                      "required": [
                        "name",
                        "exercises"
                      ],
                      "type": "object"
                    },
                    "maxItems": 7,
                    "minItems": 1,
                    "type": "array"
                  },
                  "title": {
                    "description": "A short title.",
                    "type": "string"
                  }
                },
                "required": [
                  "title",
                  "rationale",
                  "sessions"
                ],
                "type": "object"
              }
            },
            "required": [
              "plan"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "Propose meals to log. Nothing is saved: the user sees the proposal, can edit the grams and must confirm it in the app.",
          "name": "propose_meal_log",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "day": {
                "description": "The day the meal counts toward: yyyy-MM-dd, \"today\" or \"yesterday\".",
                "type": "string"
              },
              "items": {
                "description": "The foods, 1 to 12.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "grams": {
                      "description": "Estimated weight in grams.",
                      "maximum": 3000,
                      "minimum": 1,
                      "type": "number"
                    },
                    "name": {
                      "description": "What the user will read.",
                      "type": "string"
                    },
                    "usdaQuery": {
                      "description": "An English, generic USDA FoodData Central search phrase.",
                      "type": "string"
                    }
                  },
                  "required": [
                    "name",
                    "grams",
                    "usdaQuery"
                  ],
                  "type": "object"
                },
                "maxItems": 12,
                "minItems": 1,
                "type": "array"
              },
              "slot": {
                "description": "breakfast, lunch, dinner or snack.",
                "enum": [
                  "breakfast",
                  "lunch",
                  "dinner",
                  "snack"
                ],
                "type": "string"
              }
            },
            "required": [
              "day",
              "slot",
              "items"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "Propose a change to the user's goal. Nothing is saved: the user must confirm it in the app, where the planner recomputes calories and macros.",
          "name": "propose_goal_change",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "change": {
                "additionalProperties": false,
                "properties": {
                  "kind": {
                    "description": "lose, gain or maintain.",
                    "enum": [
                      "lose",
                      "gain",
                      "maintain"
                    ],
                    "type": "string"
                  },
                  "reason": {
                    "description": "One or two sentences why.",
                    "type": "string"
                  },
                  "targetWeightKg": {
                    "anyOf": [
                      {
                        "description": "Target body weight in kg, or null.",
                        "type": "number"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "weeklyRatePercent": {
                    "anyOf": [
                      {
                        "description": "Weekly body-weight change as a percent of body weight, 0 to 1, or null.",
                        "type": "number"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "workoutsPerWeek": {
                    "anyOf": [
                      {
                        "description": "Planned workouts per week, 0 to 7, or null.",
                        "type": "integer"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  }
                },
                "required": [
                  "kind",
                  "targetWeightKg",
                  "weeklyRatePercent",
                  "workoutsPerWeek",
                  "reason"
                ],
                "type": "object"
              }
            },
            "required": [
              "change"
            ],
            "type": "object"
          },
          "type": "function"
        }
      ]
    }
    """#  + "\n"
    static let chatAfterTools = #"""
    POST /v1/coach/responses
    X-Coach-Feature: chat
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 1930 characters, sha256 7896fc54c2e3c2c7>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "text": "What is my goal?",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        },
        {
          "content": [
            {
              "text": "Let me look.",
              "type": "output_text"
            }
          ],
          "role": "assistant",
          "type": "message"
        },
        {
          "arguments": "{}",
          "call_id": "call_1",
          "name": "get_goal",
          "type": "function_call"
        },
        {
          "call_id": "call_1",
          "output": "{\"goal\":{\"carbsG\":220,\"fatG\":65,\"kcal\":2100,\"kind\":\"lose\",\"proteinG\":130,\"startDay\":\"2026-12-01\",\"targetWeightKg\":68,\"weeklyRateKg\":0.35,\"workoutsPerWeek\":3},\"profile\":{\"ageYears\":31,\"heightCm\":168,\"level\":\"beginner\",\"units\":\"metric\"}}",
          "type": "function_call_output"
        }
      ],
      "max_output_tokens": 6000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "medium"
      },
      "store": false,
      "stream": true,
      "tools": [
        {
          "description": "Summaries of the user's recent workout sessions, newest first: date, exercises, sets with reps, load, average form score and velocity loss. Use before talking about their training.",
          "name": "get_sessions",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "days": {
                "description": "How many days back to look, 1 to 90.",
                "maximum": 90,
                "minimum": 1,
                "type": "integer"
              }
            },
            "required": [
              "days"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "One set in detail, rep by rep: score, timing, range of motion and rule issues. Use a set id from get_sessions.",
          "name": "get_set_detail",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "set_id": {
                "description": "A set id returned by get_sessions.",
                "type": "string"
              }
            },
            "required": [
              "set_id"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "The user's logged meals and macro totals for one day.",
          "name": "get_nutrition",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "day": {
                "description": "A date as yyyy-MM-dd, or \"today\", or \"yesterday\".",
                "type": "string"
              }
            },
            "required": [
              "day"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "The user's body weight (kg) and body fat (percent) measurements over a period: first, latest, change and a few points.",
          "name": "get_body_trend",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "days": {
                "description": "How many days back to look, 1 to 365.",
                "maximum": 365,
                "minimum": 1,
                "type": "integer"
              }
            },
            "required": [
              "days"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "The user's active goal (kind, target, calories, macros, workouts per week) and basic profile (age, height, units, training level). No name.",
          "name": "get_goal",
          "parameters": {
            "additionalProperties": false,
            "properties": {},
            "required": [],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "Propose a weekly training plan. Nothing is saved: the user sees the proposal and must confirm it in the app.",
          "name": "propose_plan",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "plan": {
                "additionalProperties": false,
                "properties": {
                  "rationale": {
                    "description": "One or two sentences why this plan fits the user.",
                    "type": "string"
                  },
                  "sessions": {
                    "description": "The training days of one week, 1 to 7.",
                    "items": {
                      "additionalProperties": false,
                      "properties": {
                        "exercises": {
                          "description": "1 to 12 exercises.",
                          "items": {
                            "additionalProperties": false,
                            "properties": {
                              "name": {
                                "description": "Exercise name.",
                                "type": "string"
                              },
                              "note": {
                                "description": "Short note; may be empty.",
                                "type": "string"
                              },
                              "reps": {
                                "description": "Reps per set, 1 to 50.",
                                "maximum": 50,
                                "minimum": 1,
                                "type": "integer"
                              },
                              "restSec": {
                                "description": "Rest between sets in seconds, 15 to 600.",
                                "maximum": 600,
                                "minimum": 15,
                                "type": "integer"
                              },
                              "sets": {
                                "description": "Sets, 1 to 10.",
                                "maximum": 10,
                                "minimum": 1,
                                "type": "integer"
                              }
                            },
                            "required": [
                              "name",
                              "sets",
                              "reps",
                              "restSec",
                              "note"
                            ],
                            "type": "object"
                          },
                          "maxItems": 12,
                          "minItems": 1,
                          "type": "array"
                        },
                        "name": {
                          "description": "For example \"Day 1: legs\".",
                          "type": "string"
                        }
                      },
                      "required": [
                        "name",
                        "exercises"
                      ],
                      "type": "object"
                    },
                    "maxItems": 7,
                    "minItems": 1,
                    "type": "array"
                  },
                  "title": {
                    "description": "A short title.",
                    "type": "string"
                  }
                },
                "required": [
                  "title",
                  "rationale",
                  "sessions"
                ],
                "type": "object"
              }
            },
            "required": [
              "plan"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "Propose meals to log. Nothing is saved: the user sees the proposal, can edit the grams and must confirm it in the app.",
          "name": "propose_meal_log",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "day": {
                "description": "The day the meal counts toward: yyyy-MM-dd, \"today\" or \"yesterday\".",
                "type": "string"
              },
              "items": {
                "description": "The foods, 1 to 12.",
                "items": {
                  "additionalProperties": false,
                  "properties": {
                    "grams": {
                      "description": "Estimated weight in grams.",
                      "maximum": 3000,
                      "minimum": 1,
                      "type": "number"
                    },
                    "name": {
                      "description": "What the user will read.",
                      "type": "string"
                    },
                    "usdaQuery": {
                      "description": "An English, generic USDA FoodData Central search phrase.",
                      "type": "string"
                    }
                  },
                  "required": [
                    "name",
                    "grams",
                    "usdaQuery"
                  ],
                  "type": "object"
                },
                "maxItems": 12,
                "minItems": 1,
                "type": "array"
              },
              "slot": {
                "description": "breakfast, lunch, dinner or snack.",
                "enum": [
                  "breakfast",
                  "lunch",
                  "dinner",
                  "snack"
                ],
                "type": "string"
              }
            },
            "required": [
              "day",
              "slot",
              "items"
            ],
            "type": "object"
          },
          "type": "function"
        },
        {
          "description": "Propose a change to the user's goal. Nothing is saved: the user must confirm it in the app, where the planner recomputes calories and macros.",
          "name": "propose_goal_change",
          "parameters": {
            "additionalProperties": false,
            "properties": {
              "change": {
                "additionalProperties": false,
                "properties": {
                  "kind": {
                    "description": "lose, gain or maintain.",
                    "enum": [
                      "lose",
                      "gain",
                      "maintain"
                    ],
                    "type": "string"
                  },
                  "reason": {
                    "description": "One or two sentences why.",
                    "type": "string"
                  },
                  "targetWeightKg": {
                    "anyOf": [
                      {
                        "description": "Target body weight in kg, or null.",
                        "type": "number"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "weeklyRatePercent": {
                    "anyOf": [
                      {
                        "description": "Weekly body-weight change as a percent of body weight, 0 to 1, or null.",
                        "type": "number"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "workoutsPerWeek": {
                    "anyOf": [
                      {
                        "description": "Planned workouts per week, 0 to 7, or null.",
                        "type": "integer"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  }
                },
                "required": [
                  "kind",
                  "targetWeightKg",
                  "weeklyRatePercent",
                  "workoutsPerWeek",
                  "reason"
                ],
                "type": "object"
              }
            },
            "required": [
              "change"
            ],
            "type": "object"
          },
          "type": "function"
        }
      ]
    }
    """#  + "\n"

    static let goalPlan = #"""
    POST /v1/coach/responses
    X-Coach-Feature: goal_plan
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 1313 characters, sha256 803d4a6bbfc07edf>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "device": {
                  "activityFactor": 1.55,
                  "bmrKcal": 1780,
                  "equation": "male",
                  "fatGMax": 103,
                  "fatGMin": 52,
                  "kcalFloor": 1500,
                  "kcalMax": 2759,
                  "kcalMin": 2319,
                  "proteinGMax": 192,
                  "proteinGMin": 128,
                  "standardPlan": {
                    "carbsG": 268,
                    "fatG": 60,
                    "kcal": 2319,
                    "proteinG": 176
                  },
                  "tdeeKcal": 2759,
                  "workoutsMax": 6,
                  "workoutsMin": 2
                },
                "goal": {
                  "kind": "lose",
                  "preferredPacePercentPerWeek": 0.5,
                  "workoutsPerWeek": 4
                },
                "task": "Set a daily calorie and macro plan for a new user.",
                "user": {
                  "ageYears": 30,
                  "heightCm": 180,
                  "sex": "male",
                  "trainingLevel": "intermediate",
                  "units": "metric",
                  "weightKg": 80
                }
              },
              "text": "Make the plan for this user.",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 4000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "low"
      },
      "store": false,
      "stream": true,
      "text": {
        "format": {
          "name": "GoalPlan",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "carbsG": {
                "description": "Daily carbohydrate in grams: what is left after protein and fat.",
                "type": "integer"
              },
              "confidence": {
                "description": "0 to 1: how well the data supports this plan.",
                "type": "number"
              },
              "fatG": {
                "description": "Daily fat in grams, inside the device's fatGMin to fatGMax.",
                "type": "integer"
              },
              "kcal": {
                "description": "Daily calories, inside the device's kcalMin to kcalMax.",
                "type": "integer"
              },
              "proteinG": {
                "description": "Daily protein in grams, inside the device's proteinGMin to proteinGMax.",
                "type": "integer"
              },
              "rationale": {
                "description": "One or two plain sentences, at most 220 characters, that cite the user's own numbers.",
                "type": "string"
              },
              "safetyFlag": {
                "additionalProperties": false,
                "properties": {
                  "level": {
                    "description": "none, caution or stop.",
                    "enum": [
                      "none",
                      "caution",
                      "stop"
                    ],
                    "type": "string"
                  },
                  "note": {
                    "description": "Short note; empty when level is none.",
                    "type": "string"
                  }
                },
                "required": [
                  "level",
                  "note"
                ],
                "type": "object"
              },
              "weeklyRatePercent": {
                "description": "Body mass change per week in percent, never above the user's preferred pace; 0 to maintain.",
                "type": "number"
              },
              "workoutsPerWeek": {
                "description": "Planned workouts per week, inside the device's workoutsMin to workoutsMax.",
                "type": "integer"
              }
            },
            "required": [
              "kcal",
              "proteinG",
              "carbsG",
              "fatG",
              "weeklyRatePercent",
              "workoutsPerWeek",
              "rationale",
              "safetyFlag",
              "confidence"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"

    static let goalPlanChinese = #"""
    POST /v1/coach/responses
    X-Coach-Feature: goal_plan
    Accept: text/event-stream
    Content-Type: application/json

    {
      "input": [
        {
          "content": [
            {
              "text": "<developer text: 1331 characters, sha256 578468796ea22d3e>",
              "type": "input_text"
            }
          ],
          "role": "developer",
          "type": "message"
        },
        {
          "content": [
            {
              "dataJSON": {
                "device": {
                  "activityFactor": 1.55,
                  "bmrKcal": 1780,
                  "equation": "male",
                  "fatGMax": 103,
                  "fatGMin": 52,
                  "kcalFloor": 1500,
                  "kcalMax": 2759,
                  "kcalMin": 2319,
                  "proteinGMax": 192,
                  "proteinGMin": 128,
                  "standardPlan": {
                    "carbsG": 268,
                    "fatG": 60,
                    "kcal": 2319,
                    "proteinG": 176
                  },
                  "tdeeKcal": 2759,
                  "workoutsMax": 6,
                  "workoutsMin": 2
                },
                "goal": {
                  "kind": "lose",
                  "preferredPacePercentPerWeek": 0.5,
                  "workoutsPerWeek": 4
                },
                "task": "Set a daily calorie and macro plan for a new user.",
                "user": {
                  "ageYears": 30,
                  "heightCm": 180,
                  "sex": "male",
                  "trainingLevel": "intermediate",
                  "units": "metric",
                  "weightKg": 80
                }
              },
              "text": "Make the plan for this user.",
              "type": "input_text"
            }
          ],
          "role": "user",
          "type": "message"
        }
      ],
      "max_output_tokens": 4000,
      "model": "muse-spark-1.3",
      "reasoning": {
        "effort": "low"
      },
      "store": false,
      "stream": true,
      "text": {
        "format": {
          "name": "GoalPlan",
          "schema": {
            "additionalProperties": false,
            "properties": {
              "carbsG": {
                "description": "Daily carbohydrate in grams: what is left after protein and fat.",
                "type": "integer"
              },
              "confidence": {
                "description": "0 to 1: how well the data supports this plan.",
                "type": "number"
              },
              "fatG": {
                "description": "Daily fat in grams, inside the device's fatGMin to fatGMax.",
                "type": "integer"
              },
              "kcal": {
                "description": "Daily calories, inside the device's kcalMin to kcalMax.",
                "type": "integer"
              },
              "proteinG": {
                "description": "Daily protein in grams, inside the device's proteinGMin to proteinGMax.",
                "type": "integer"
              },
              "rationale": {
                "description": "One or two plain sentences, at most 220 characters, that cite the user's own numbers.",
                "type": "string"
              },
              "safetyFlag": {
                "additionalProperties": false,
                "properties": {
                  "level": {
                    "description": "none, caution or stop.",
                    "enum": [
                      "none",
                      "caution",
                      "stop"
                    ],
                    "type": "string"
                  },
                  "note": {
                    "description": "Short note; empty when level is none.",
                    "type": "string"
                  }
                },
                "required": [
                  "level",
                  "note"
                ],
                "type": "object"
              },
              "weeklyRatePercent": {
                "description": "Body mass change per week in percent, never above the user's preferred pace; 0 to maintain.",
                "type": "number"
              },
              "workoutsPerWeek": {
                "description": "Planned workouts per week, inside the device's workoutsMin to workoutsMax.",
                "type": "integer"
              }
            },
            "required": [
              "kcal",
              "proteinG",
              "carbsG",
              "fatG",
              "weeklyRatePercent",
              "workoutsPerWeek",
              "rationale",
              "safetyFlag",
              "confidence"
            ],
            "type": "object"
          },
          "strict": true,
          "type": "json_schema"
        }
      }
    }
    """#  + "\n"
}
